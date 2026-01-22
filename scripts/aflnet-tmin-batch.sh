#!/usr/bin/env bash
set -euo pipefail

# Batch-run afl-tmin for a corpus directory using AFLNet's aflnet-exec wrapper.
#
# Default behavior matches the command you provided:
#   afl-tmin -i <one_input> -o <one_output> -- \
#     ./aflnet-exec -N tcp://127.0.0.1/8080 -P HTTP -I len -- \
#     ./bin/appweb 0.0.0.0:8080 ./webLib/
#
# You can override INPUT_DIR / OUTPUT_DIR via environment variables.

INPUT_DIR="${INPUT_DIR:-minimized-raw}"
OUTPUT_DIR="${OUTPUT_DIR:-tmined}"

# Parallelism (number of concurrent afl-tmin processes).
# Set via JOBS env var or -j/--jobs. Default: 1 (serial).
JOBS="${JOBS:-1}"

# Logging: each worker slot (1..JOBS) gets its own log file under LOG_DIR.
LOG_DIR="${LOG_DIR:-$OUTPUT_DIR/logs}"

AFL_TMIN_BIN="${AFL_TMIN_BIN:-afl-tmin}"
AFLNET_EXEC_BIN="${AFLNET_EXEC_BIN:-./aflnet-exec}"

# afl-tmin limits:
# - Memory: afl-tmin defaults to ~50 MB; set to 'none' to disable.
# - Timeout: cannot be fully disabled; set very large to effectively disable.
MEM_LIMIT="${MEM_LIMIT:-none}"
TIMEOUT_MS="${TIMEOUT_MS:-600000}"

NETINFO="${NETINFO:-tcp://127.0.0.1/8080}"
PROTO="${PROTO:-HTTP}"
INPUT_MODE="${INPUT_MODE:-len}"

# Base port for per-job port allocation when running with JOBS>1.
# For the default appweb example, job ports will be PORT_BASE, PORT_BASE+1, ...
PORT_BASE="${PORT_BASE:-8080}"

# Optional server command template.
# If set, should include {PORT} when JOBS>1 (so each job can bind to a unique port).
SERVER_CMD="${SERVER_CMD:-}"

usage() {
  cat <<EOF
Usage: aflnet-tmin-batch.sh [options]

Options:
  -i, --input-dir DIR    Input corpus directory (default: ${INPUT_DIR})
  -o, --output-dir DIR   Output directory for minimized files (default: ${OUTPUT_DIR})
  -j, --jobs N           Run N afl-tmin jobs in parallel (default: ${JOBS})
  --port-base N          Base port for per-job allocation (default: ${PORT_BASE})
  --log-dir DIR          Directory to write per-worker logs (default: ${LOG_DIR})
  -h, --help             Show this help

You can also configure via environment variables:
  INPUT_DIR, OUTPUT_DIR, JOBS, AFL_TMIN_BIN, AFLNET_EXEC_BIN,
  MEM_LIMIT, TIMEOUT_MS, NETINFO, PROTO, INPUT_MODE, SERVER_CMD, PORT_BASE, LOG_DIR
EOF
}

while [[ ${#} -gt 0 ]]; do
  case "$1" in
    -i|--input-dir)
      INPUT_DIR="$2"; shift 2 ;;
    -o|--output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    -j|--jobs)
      JOBS="$2"; shift 2 ;;
    --port-base)
      PORT_BASE="$2"; shift 2 ;;
    --log-dir)
      LOG_DIR="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid jobs value: '$JOBS' (must be a positive integer)" >&2
  exit 2
fi

if (( JOBS > 1 )); then
  # wait -n requires bash >= 4.3
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Bash ${BASH_VERSION} does not support 'wait -n'; falling back to serial execution." >&2
    JOBS=1
  fi
fi

if [[ ! "$PORT_BASE" =~ ^[0-9]+$ ]]; then
  echo "Invalid port base: '$PORT_BASE' (must be an integer)" >&2
  exit 2
fi

if (( JOBS > 1 )) && [[ -n "$SERVER_CMD" ]] && [[ "$SERVER_CMD" != *"{PORT}"* ]]; then
  echo "Parallel jobs requested (JOBS=$JOBS) but SERVER_CMD does not include '{PORT}'." >&2
  echo "Add '{PORT}' to SERVER_CMD so each job can use a unique port, e.g.:" >&2
  echo "  SERVER_CMD='./bin/appweb 0.0.0.0:{PORT} ./webLib/'" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$LOG_DIR"

shopt -s nullglob
inputs=("$INPUT_DIR"/*)
shopt -u nullglob

if (( ${#inputs[@]} == 0 )); then
  echo "No inputs found in '$INPUT_DIR'" >&2
  exit 1
fi

failures=0

# Filter to regular files to get an accurate total.
files=()
for p in "${inputs[@]}"; do
  [[ -f "$p" ]] && files+=("$p")
done

if (( ${#files[@]} == 0 )); then
  echo "No regular files found in '$INPUT_DIR'" >&2
  exit 1
fi

count=0

done_count=0
ok_count=0

total=${#files[@]}

print_progress() {
  # Single-line refresh in the terminal.
  printf '\r\033[Kdone=%d/%d ok=%d fail=%d running=%d' \
    "$done_count" "$total" "$ok_count" "$failures" "$running" >&2
}

run_one() {
  local in_path="$1"
  local out_path="$2"
  local port="$3"

  local job_netinfo="$NETINFO"
  if [[ "$job_netinfo" == *"{PORT}"* ]]; then
    job_netinfo="${job_netinfo//\{PORT\}/$port}"
  elif [[ "$job_netinfo" =~ ^(.*/)[0-9]+$ ]]; then
    job_netinfo="${BASH_REMATCH[1]}$port"
  fi

  local -a server_wrapped
  if [[ -n "$SERVER_CMD" ]]; then
    local job_server_cmd="$SERVER_CMD"
    job_server_cmd="${job_server_cmd//\{PORT\}/$port}"
    server_wrapped=(bash -lc "$job_server_cmd")
  else
    server_wrapped=(./bin/appweb "0.0.0.0:$port" ./webLib/)
  fi

  # IMPORTANT: the first '--' ends afl-tmin options; the second '--' ends aflnet-exec options.
  local -a tmin_args=( -i "$in_path" -o "$out_path" )
  if [[ -n "${MEM_LIMIT}" ]]; then
    tmin_args+=( -m "$MEM_LIMIT" )
  fi
  if [[ -n "${TIMEOUT_MS}" ]]; then
    tmin_args+=( -t "$TIMEOUT_MS" )
  fi

  "$AFL_TMIN_BIN" "${tmin_args[@]}" -- \
    "$AFLNET_EXEC_BIN" -N "$job_netinfo" -P "$PROTO" -I "$INPUT_MODE" -- \
    "${server_wrapped[@]}"
}

running=0

cleanup() {
  # Ensure progress line ends cleanly.
  printf '\n' >&2
  [[ -n "${_TMPDIR:-}" ]] && rm -rf "$_TMPDIR" || true
}

trap cleanup EXIT

_TMPDIR="$(mktemp -d -t aflnet-tmin-batch.XXXXXX)"
event_fifo="$_TMPDIR/events.fifo"
mkfifo "$event_fifo"

# Open FIFO read+write to avoid blocking on open.
exec 3<>"$event_fifo"

declare -a slot_pid

alloc_slot() {
  local s
  for ((s=1; s<=JOBS; s++)); do
    if [[ -z "${slot_pid[$s]:-}" ]]; then
      printf '%s' "$s"
      return 0
    fi
  done
  return 1
}

start_task() {
  local slot="$1"
  local in_path="$2"
  local out_path="$3"
  local port="$4"
  local job_log="$LOG_DIR/job${slot}.log"

  (
    local st=0
    {
      echo "=== BEGIN $(date -Iseconds) slot=$slot input='$in_path' out='$out_path' port=$port ==="
      if run_one "$in_path" "$out_path" "$port"; then
        st=0
      else
        st=$?
      fi
      echo "=== END   $(date -Iseconds) slot=$slot status=$st ==="
      echo
    } >>"$job_log" 2>&1
    # Notify parent: "<slot> <exit_status>"
    printf '%s %s\n' "$slot" "$st" >&3
    exit "$st"
  ) &

  slot_pid[$slot]="$!"
  running=$((running + 1))
}

print_progress

for in_path in "${files[@]}"; do
  base_name="$(basename "$in_path")"
  out_path="$OUTPUT_DIR/$base_name"

  count=$((count + 1))
  port=$((PORT_BASE + count - 1))

  # Wait for a free slot if we are at capacity.
  while (( running >= JOBS )); do
    if ! read -r finished_slot st <&3; then
      break
    fi
    running=$((running - 1))
    slot_pid[$finished_slot]=""
    done_count=$((done_count + 1))
    if [[ "$st" == "0" ]]; then
      ok_count=$((ok_count + 1))
    else
      failures=$((failures + 1))
    fi
    print_progress
  done

  slot="$(alloc_slot)"
  start_task "$slot" "$in_path" "$out_path" "$port"
  print_progress
done

while (( running > 0 )); do
  if ! read -r finished_slot st <&3; then
    break
  fi
  running=$((running - 1))
  slot_pid[$finished_slot]=""
  done_count=$((done_count + 1))
  if [[ "$st" == "0" ]]; then
    ok_count=$((ok_count + 1))
  else
    failures=$((failures + 1))
  fi
  print_progress
done

printf '\n' >&2

echo "Done. total=$count failures=$failures output_dir='$OUTPUT_DIR'" >&2

# Exit non-zero if any job failed.
(( failures == 0 ))
