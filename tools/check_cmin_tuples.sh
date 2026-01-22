#!/usr/bin/env bash
set -u

# Compare tuple (coverage) union between an original corpus directory and a
# minimized corpus directory by re-running afl-showmap -Z on every file.
#
# This answers: "Did minimization reduce total coverage?"
#
# NOTE: For AFLNet, use aflnet-exec as the target:
#   ./tools/check_cmin_tuples.sh -i out/queue -m minimized -t 2000 -- \
#     ./aflnet-exec -N tcp://127.0.0.1/8554 -P RTSP -I raw -D 10000 -K -- ./server 8554

usage() {
  cat >&2 <<'EOF'
Usage:
  check_cmin_tuples.sh -i <orig_dir> -m <min_dir> [options] [--] <target_cmd...>

Required:
  -i dir      Original corpus directory
  -m dir      Minimized corpus directory

Options (match your afl-cmin params as closely as possible):
  -o dir      Output directory for reports (default: <min_dir>/tuple-check)
  -t msec     Timeout passed to afl-showmap (default: none)
  -M megs     Memory limit passed to afl-showmap (default: 100)
  -e          Edge coverage only (ignore hit counts)
  -Q          QEMU mode
  -v          Verbose: show afl-showmap stderr/stdout
  -r N        Repeat each input N times and union tuples (default: 1)
  -n N        Repeat the whole measurement N rounds (default: 1)
  -S          Enable "stable missing tuples" analysis (requires -n >= 2)
  -p PCT      Stable-orig threshold: tuple must appear in >=PCT% of orig rounds (default: 80)
  -q PCT      Stable-miss threshold: tuple must appear in <=PCT% of min rounds (default: 20)
  -H          Normalize tuples by ignoring hitcount class (strip leading digit in -Z output)

Example (AFLNet):
  ./tools/check_cmin_tuples.sh -i out/queue -m minimized -t 2000 -e -- \
    ./aflnet-exec -N tcp://127.0.0.1/8554 -P RTSP -I raw -D 10000 -K -- ./server 8554

Example (stable missing tuples, 5 rounds):
  ./tools/check_cmin_tuples.sh -n 5 -S -p 80 -q 20 -i out/queue -m minimized -e -- \
    ./aflnet-exec -N tcp://127.0.0.1/8554 -P RTSP -I raw -D 10000 -K -- ./server 8554
EOF
}

ORIG_DIR=""
MIN_DIR=""
OUT_DIR=""
TIMEOUT="none"
MEM_LIMIT="100"
EDGES_ONLY=0
QEMU_MODE=0
VERBOSE=0
REPEAT=1
ROUNDS=1
STABLE_MODE=0
ORIG_STABLE_PCT=80
MIN_MISS_PCT=20
IGNORE_HITCOUNT=0

while getopts "+i:m:o:t:M:eQvr:n:Sp:q:H" opt; do
  case "$opt" in
    i) ORIG_DIR="$OPTARG" ;;
    m) MIN_DIR="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    M) MEM_LIMIT="$OPTARG" ;;
    e) EDGES_ONLY=1 ;;
    Q) QEMU_MODE=1 ;;
    v) VERBOSE=1 ;;
    r) REPEAT="$OPTARG" ;;
    n) ROUNDS="$OPTARG" ;;
    S) STABLE_MODE=1 ;;
    p) ORIG_STABLE_PCT="$OPTARG" ;;
    q) MIN_MISS_PCT="$OPTARG" ;;
    H) IGNORE_HITCOUNT=1 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

if [[ -z "$ORIG_DIR" || -z "$MIN_DIR" ]]; then
  usage
  exit 1
fi

# Note: bash getopts consumes the first standalone "--".
# Accept both styles:
#   script ... -- <target_cmd...>
#   script ... <target_cmd...>
if [[ $# -ge 1 && "$1" == "--" ]]; then
  shift 1
fi

if [[ $# -lt 1 ]]; then
  usage
  echo >&2
  echo "[-] Missing target command" >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$MIN_DIR/tuple-check"
fi

if ! [[ "$REPEAT" =~ ^[0-9]+$ ]] || [[ "$REPEAT" -lt 1 ]]; then
  echo "[-] Error: -r expects an integer >= 1" >&2
  exit 1
fi

if ! [[ "$ROUNDS" =~ ^[0-9]+$ ]] || [[ "$ROUNDS" -lt 1 ]]; then
  echo "[-] Error: -n expects an integer >= 1" >&2
  exit 1
fi

if ! [[ "$ORIG_STABLE_PCT" =~ ^[0-9]+$ ]] || [[ "$ORIG_STABLE_PCT" -lt 0 || "$ORIG_STABLE_PCT" -gt 100 ]]; then
  echo "[-] Error: -p expects an integer percent 0..100" >&2
  exit 1
fi

if ! [[ "$MIN_MISS_PCT" =~ ^[0-9]+$ ]] || [[ "$MIN_MISS_PCT" -lt 0 || "$MIN_MISS_PCT" -gt 100 ]]; then
  echo "[-] Error: -q expects an integer percent 0..100" >&2
  exit 1
fi

if [[ "$STABLE_MODE" -eq 1 && "$ROUNDS" -lt 2 ]]; then
  echo "[-] Error: -S requires -n >= 2" >&2
  exit 1
fi

normalize_stream() {
  # afl-showmap -Z outputs lines like: "<class><index>" where <class> is 1 digit.
  # With -H, we strip the leading class digit to compare edge indices only.
  if [[ "$IGNORE_HITCOUNT" -eq 1 ]]; then
    awk '{ sub(/^[0-9]/, ""); if (length($0)) print $0; }'
  else
    cat
  fi
}

# Resolve afl-showmap.
if [[ -n "${AFL_PATH:-}" ]]; then
  SHOWMAP="$AFL_PATH/afl-showmap"
else
  SHOWMAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/afl-showmap"
fi

if [[ ! -x "$SHOWMAP" ]]; then
  SHOWMAP="$(command -v afl-showmap || true)"
  if [[ -z "$SHOWMAP" || ! -x "$SHOWMAP" ]]; then
    echo "[-] Error: can't find afl-showmap (set AFL_PATH, or ensure afl-showmap is in PATH, or run from the AFLNet repo root)." >&2
    exit 1
  fi
fi

if [[ ! -d "$ORIG_DIR" ]]; then
  echo "[-] Error: original dir not found: $ORIG_DIR" >&2
  exit 1
fi

if [[ ! -d "$MIN_DIR" ]]; then
  echo "[-] Error: minimized dir not found: $MIN_DIR" >&2
  exit 1
fi

showmap_args=("-m" "$MEM_LIMIT" "-t" "$TIMEOUT" "-Z")
if [[ "$EDGES_ONLY" -eq 1 ]]; then
  showmap_args+=("-e")
fi
if [[ "$QEMU_MODE" -eq 1 ]]; then
  showmap_args+=("-Q")
fi

# Run afl-showmap for each file in a directory.
# Writes per-input traces, then produces a union list in <out_prefix>.tuples.
collect_dir() {
  local in_dir="$1"
  local trace_dir="$2"
  local out_prefix="$3"
  shift 3

  local total
  total=$(find "$in_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
  if [[ "$total" == "0" ]]; then
    echo "[-] Error: no files in $in_dir" >&2
    return 2
  fi

  local i=0
  local failures=0
  local first_fail_file=""

  while IFS= read -r -d '' f; do
    i=$((i+1))
    local base
    base=$(basename "$f")
    if [[ "$REPEAT" -eq 1 ]]; then
      printf "\r[*] showmap %s (%d/%d)" "$out_prefix" "$i" "$total" >&2
    else
      printf "\r[*] showmap %s (%d/%d) x%d" "$out_prefix" "$i" "$total" "$REPEAT" >&2
    fi

    # Repeat N times and union per-input tuples to reduce nondeterminism.
    if [[ "$REPEAT" -gt 1 ]]; then
      rm -f "$trace_dir/$base" "$trace_dir/$base".r* 2>/dev/null || true

      for rep in $(seq 1 "$REPEAT"); do
        local rep_out="$trace_dir/$base.r$rep"

        if [[ "$VERBOSE" -eq 1 ]]; then
          if ! AFL_CMIN_ALLOW_ANY=1 "$SHOWMAP" "${showmap_args[@]}" -o "$rep_out" -- "$@" <"$f"; then
            failures=$((failures+1))
            [[ -z "$first_fail_file" ]] && first_fail_file="$f"
          fi
        else
          if ! AFL_CMIN_ALLOW_ANY=1 "$SHOWMAP" "${showmap_args[@]}" -o "$rep_out" -- "$@" <"$f" >/dev/null 2>&1; then
            failures=$((failures+1))
            [[ -z "$first_fail_file" ]] && first_fail_file="$f"
          fi
        fi
      done

      # Union per-input tuples (ignore missing rep outputs).
      ls "$trace_dir/$base".r* 2>/dev/null \
        | xargs -n 1 cat 2>/dev/null \
        | normalize_stream \
        | sort -u >"$trace_dir/$base" || true
      rm -f "$trace_dir/$base".r* 2>/dev/null || true
      continue
    fi

    # AFL_CMIN_ALLOW_ANY=1 tolerates non-0 exit codes (crash/timeout) in cmin workflows.
    # By default we silence afl-showmap output; use -v to see details.
    if [[ "$VERBOSE" -eq 1 ]]; then
      if ! AFL_CMIN_ALLOW_ANY=1 "$SHOWMAP" "${showmap_args[@]}" -o "$trace_dir/$base" -- "$@" <"$f"; then
        failures=$((failures+1))
        [[ -z "$first_fail_file" ]] && first_fail_file="$f"
      fi
    else
      if ! AFL_CMIN_ALLOW_ANY=1 "$SHOWMAP" "${showmap_args[@]}" -o "$trace_dir/$base" -- "$@" <"$f" >/dev/null 2>&1; then
        failures=$((failures+1))
        [[ -z "$first_fail_file" ]] && first_fail_file="$f"
      fi
    fi

  done < <(find "$in_dir" -maxdepth 1 -type f -print0 | sort -z)

  echo >&2
  if [[ "$failures" -gt 0 ]]; then
    echo "[!] Warning: $failures/$total runs returned non-zero (crash/timeout/execfail)." >&2
    echo "    This can cause apparent coverage loss due to instability." >&2
    if [[ -n "$first_fail_file" ]]; then
      echo "    To debug one failing case, re-run with: " >&2
      echo "      AFL_CMIN_ALLOW_ANY=1 \"$SHOWMAP\" ${showmap_args[*]} -o /tmp/${out_prefix}.z -- $* < \"$first_fail_file\"" >&2
    fi
  fi

  # Union of tuples.
  find "$trace_dir" -maxdepth 1 -type f -print0 \
    | xargs -0 -n 1 cat \
    | normalize_stream \
    | sort -u >"$OUT_DIR/$out_prefix.tuples"

  wc -l <"$OUT_DIR/$out_prefix.tuples" | tr -d ' ' >"$OUT_DIR/$out_prefix.count"
}

TARGET_CMD=("$@")

BASE_OUT_DIR="$OUT_DIR"

run_one_round() {
  local round="$1"
  local round_dir="$BASE_OUT_DIR"
  if [[ "$ROUNDS" -gt 1 || "$STABLE_MODE" -eq 1 ]]; then
    round_dir="$BASE_OUT_DIR/rounds/r$round"
  fi

  mkdir -p "$round_dir/traces/orig" "$round_dir/traces/min" || exit 1

  OUT_DIR="$round_dir"
  collect_dir "$ORIG_DIR" "$OUT_DIR/traces/orig" "orig" "${TARGET_CMD[@]}"
  collect_dir "$MIN_DIR"  "$OUT_DIR/traces/min"  "min"  "${TARGET_CMD[@]}"

  comm -23 "$OUT_DIR/orig.tuples" "$OUT_DIR/min.tuples" >"$OUT_DIR/missing.tuples" || true

  local o
  local m
  local miss
  o=$(cat "$OUT_DIR/orig.count")
  m=$(cat "$OUT_DIR/min.count")
  miss=$(wc -l <"$OUT_DIR/missing.tuples" | tr -d ' ')

  echo "[+] Round $round/$ROUNDS" 
  echo "[+] Tuple union (orig): $o" 
  echo "[+] Tuple union (min):  $m" 
  echo "[+] Missing tuples:      $miss" 
  echo "[+] Report dir:          $OUT_DIR" 

  if [[ "${ALLOW_EMPTY_TUPLES:-0}" != "1" && "$o" == "0" && "$m" == "0" ]]; then
    echo "[!] Error: tuple union is 0 for both corpora." >&2
    echo "    This usually means the server is NOT AFL-instrumented, or afl-showmap failed for all inputs." >&2
    echo "    Re-run with -v to see afl-showmap errors, and ensure your server binary was built with afl-clang-fast/afl-gcc." >&2
    exit 3
  fi
}

if [[ "$ROUNDS" -eq 1 && "$STABLE_MODE" -eq 0 ]]; then
  run_one_round 1

  miss_n=$(wc -l <"$BASE_OUT_DIR/missing.tuples" | tr -d ' ')
  if [[ "$miss_n" != "0" ]]; then
    echo "[!] Coverage decreased: see $BASE_OUT_DIR/missing.tuples" >&2
    exit 2
  fi
  echo "[+] OK: minimized corpus preserves tuple union."
  exit 0
fi

# Multi-round: collect frequency across rounds and compute stable-missing tuples.
declare -A orig_freq
declare -A min_freq
declare -A miss_set

for round in $(seq 1 "$ROUNDS"); do
  run_one_round "$round"

  round_dir="$BASE_OUT_DIR/rounds/r$round"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    orig_freq["$t"]=$(( ${orig_freq["$t"]:-0} + 1 ))
  done <"$round_dir/orig.tuples"

  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    min_freq["$t"]=$(( ${min_freq["$t"]:-0} + 1 ))
  done <"$round_dir/min.tuples"

  # Candidate missing tuples: union across all rounds.
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    miss_set["$t"]=1
  done <"$round_dir/missing.tuples"
done

orig_need=$(( (ROUNDS * ORIG_STABLE_PCT + 99) / 100 ))
min_max=$(( (ROUNDS * MIN_MISS_PCT) / 100 ))

stable_file="$BASE_OUT_DIR/stable_missing.tuples"
unstable_file="$BASE_OUT_DIR/unstable_missing.tuples"
: >"$stable_file"
: >"$unstable_file"

# Classify candidates gathered from all rounds.
for t in "${!miss_set[@]}"; do
  o=${orig_freq["$t"]:-0}
  m=${min_freq["$t"]:-0}

  if [[ "$o" -ge "$orig_need" && "$m" -le "$min_max" ]]; then
    echo "$t" >>"$stable_file"
  else
    echo "$t" >>"$unstable_file"
  fi
done

sort -u -o "$stable_file" "$stable_file"
sort -u -o "$unstable_file" "$unstable_file"

stable_n=$(wc -l <"$stable_file" | tr -d ' ')
unstable_n=$(wc -l <"$unstable_file" | tr -d ' ')

echo "[+] Stable missing analysis" 
echo "[+] Rounds:              $ROUNDS" 
echo "[+] Stable-orig >=:       $ORIG_STABLE_PCT% (count >= $orig_need)" 
echo "[+] Stable-miss <=:       $MIN_MISS_PCT% (count <= $min_max)" 
echo "[+] Stable missing:       $stable_n  (see $stable_file)" 
echo "[+] Unstable missing:     $unstable_n (see $unstable_file)" 

if [[ "$stable_n" != "0" ]]; then
  echo "[!] Coverage likely decreased (stable missing tuples detected)." >&2
  exit 2
fi

echo "[+] OK: no stable missing tuples detected (missing appears unstable/noisy)."