#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
verify_cmin_coverage.sh: run afl-cmin for AFLNet-style network inputs and verify
that minimized corpus covers the same tuple set as the original corpus.

Usage:
  scripts/verify_cmin_coverage.sh -i IN_DIR -o OUT_DIR \
    -N tcp://IP/PORT -P PROTO [-I auto|raw|len] [cmin opts] [exec opts] -- server [args...]

Required:
  -i DIR        Input corpus dir (e.g., out/queue)
  -o DIR        Output dir for minimized corpus (must not exist or be empty)
  -N NETINFO    e.g., tcp://127.0.0.1/8081
  -P PROTO      e.g., HTTP, RTSP, FTP, ...
  --            Separator; everything after is the server command

Common afl-cmin / afl-showmap opts:
  -m MEM        Memory limit (e.g., none)
  -t MS         Timeout in ms (e.g., 100)
  -e            Edges-only mode
  -Q            QEMU mode
  -C            Keep crashing inputs only

Common aflnet-exec opts:
  -I MODE       Input mode: auto|raw|len (default: raw)
  -D USEC       Wait before connecting (default: aflnet-exec default)
  -K            Graceful server termination (SIGTERM)
  -W MS         Poll timeout in ms
  -w USEC       Socket send/recv timeout in usec

Example (mirrors your afl-fuzz flags as closely as possible):
  AFL_KEEP_TRACES=1 scripts/verify_cmin_coverage.sh \
    -i fuzz-out-multi/s1/queue -o test-cmin \
    -N tcp://127.0.0.1/8081 -P HTTP -I raw -m none -t 100 -W 10 -w 20 -K -- \
    ./bin/appweb 0.0.0.0:8081 ./webLib

Exit codes:
  0 = OK (no missing tuples)
  2 = Missing tuples detected
  1 = Usage / runtime error
EOF
}

# Defaults
IN_DIR=""
OUT_DIR=""
NETINFO=""
PROTO=""
INPUT_MODE="raw"

# afl-cmin opts
MEM_LIMIT=""
TIMEOUT_MS=""
EDGES_ONLY=0
CRASHES_ONLY=0
QEMU_MODE=0

# aflnet-exec opts
SERVER_WAIT=""
GRACEFUL=0
POLL_MS=""
SOCK_USEC=""

# Parse args until "--"
CALLER_PWD="$PWD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) IN_DIR="$2"; shift 2;;
    -o) OUT_DIR="$2"; shift 2;;
    -N) NETINFO="$2"; shift 2;;
    -P) PROTO="$2"; shift 2;;

    -I) INPUT_MODE="$2"; shift 2;;
    -D) SERVER_WAIT="$2"; shift 2;;
    -K) GRACEFUL=1; shift 1;;
    -W) POLL_MS="$2"; shift 2;;
    -w) SOCK_USEC="$2"; shift 2;;

    -m) MEM_LIMIT="$2"; shift 2;;
    -t) TIMEOUT_MS="$2"; shift 2;;
    -e) EDGES_ONLY=1; shift 1;;
    -C) CRASHES_ONLY=1; shift 1;;
    -Q) QEMU_MODE=1; shift 1;;

    -h|--help) usage; exit 0;;
    --) shift 1; break;;

    *)
      echo "[-] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IN_DIR" || -z "$OUT_DIR" || -z "$NETINFO" || -z "$PROTO" || $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

# Resolve paths relative to the directory the script was invoked from.
# The script later changes directory into the AFLNet repo.
if [[ "$IN_DIR" = /* ]]; then IN_DIR_IN="$IN_DIR"; else IN_DIR_IN="$CALLER_PWD/$IN_DIR"; fi
if [[ "$OUT_DIR" = /* ]]; then OUT_DIR_IN="$OUT_DIR"; else OUT_DIR_IN="$CALLER_PWD/$OUT_DIR"; fi

if command -v python3 >/dev/null 2>&1; then
  IN_DIR_ABS="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$IN_DIR_IN")"
  OUT_DIR_ABS="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT_DIR_IN")"
else
  IN_DIR_ABS="$IN_DIR_IN"
  OUT_DIR_ABS="$OUT_DIR_IN"
fi

IN_DIR="$IN_DIR_ABS"
OUT_DIR="$OUT_DIR_ABS"

if [[ ! -d "$IN_DIR" ]]; then
  echo "[-] Error: input directory not found: $IN_DIR" >&2
  exit 1
fi

# Locate tools relative to this script's directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AFL_CMIN="$REPO_ROOT/afl-cmin"
AFLNET_EXEC="$REPO_ROOT/aflnet-exec"

if [[ ! -x "$AFL_CMIN" ]]; then
  echo "[-] Error: can't find executable afl-cmin at: $AFL_CMIN" >&2
  exit 1
fi

if [[ ! -x "$AFLNET_EXEC" ]]; then
  # fallback: PATH
  AFLNET_EXEC="$(command -v aflnet-exec || true)"
fi

if [[ -z "$AFLNET_EXEC" || ! -x "$AFLNET_EXEC" ]]; then
  echo "[-] Error: can't find executable aflnet-exec (build it or put it in PATH)" >&2
  exit 1
fi

# Build argument arrays.
CMIN_ARGS=("-i" "$IN_DIR" "-o" "$OUT_DIR")
if [[ -n "$MEM_LIMIT" ]]; then CMIN_ARGS+=("-m" "$MEM_LIMIT"); fi
if [[ -n "$TIMEOUT_MS" ]]; then CMIN_ARGS+=("-t" "$TIMEOUT_MS"); fi
if [[ "$EDGES_ONLY" -eq 1 ]]; then CMIN_ARGS+=("-e"); fi
if [[ "$CRASHES_ONLY" -eq 1 ]]; then CMIN_ARGS+=("-C"); fi
if [[ "$QEMU_MODE" -eq 1 ]]; then CMIN_ARGS+=("-Q"); fi

EXEC_ARGS=("-N" "$NETINFO" "-P" "$PROTO" "-I" "$INPUT_MODE")
if [[ -n "$SERVER_WAIT" ]]; then EXEC_ARGS+=("-D" "$SERVER_WAIT"); fi
if [[ "$GRACEFUL" -eq 1 ]]; then EXEC_ARGS+=("-K"); fi
if [[ -n "$POLL_MS" ]]; then EXEC_ARGS+=("-W" "$POLL_MS"); fi
if [[ -n "$SOCK_USEC" ]]; then EXEC_ARGS+=("-w" "$SOCK_USEC"); fi

# afl-cmin will refuse non-instrumented target unless AFL_SKIP_BIN_CHECK=1.
# In our workflow, the server is instrumented; aflnet-exec may not be.
export AFL_SKIP_BIN_CHECK=1

echo "[*] Running afl-cmin (keeping traces)..." >&2
echo "    IN : $IN_DIR" >&2
echo "    OUT: $OUT_DIR" >&2

# Keep traces regardless of caller environment; user can still override to 0.
export AFL_KEEP_TRACES="${AFL_KEEP_TRACES:-1}"

# Run minimization.
cd "$REPO_ROOT"
"$AFL_CMIN" "${CMIN_ARGS[@]}" -- "$AFLNET_EXEC" "${EXEC_ARGS[@]}" -- "$@"

TRACE_DIR="$OUT_DIR/.traces"
if [[ ! -d "$TRACE_DIR" ]]; then
  echo "[-] Error: trace dir not found: $TRACE_DIR" >&2
  exit 1
fi

echo "[*] Computing tuple-set unions..." >&2

TMPDIR="${TMPDIR:-/tmp}"
ALL_TUP="$TMPDIR/afl_all_$$.tuples"
KEPT_TUP="$TMPDIR/afl_kept_$$.tuples"
MISS_TUP="$TMPDIR/afl_missing_$$.tuples"

# 1) All tuples from all input traces.
find "$TRACE_DIR" -maxdepth 1 -type f -not -name '.*' -print0 | xargs -0 cat | sort -u >"$ALL_TUP"

# 2) Kept tuples: iterate output corpus files, and cat matching trace.
(
  cd "$OUT_DIR"
  find . -maxdepth 1 -type f -not -name '.*' -printf '%f\0' | \
    xargs -0 -I{} bash -c 'cat "$0/.traces/{}"' "$OUT_DIR"
) | sort -u >"$KEPT_TUP"

# 3) Missing tuples.
comm -23 "$ALL_TUP" "$KEPT_TUP" >"$MISS_TUP" || true

MISS_COUNT=$(wc -l <"$MISS_TUP" | tr -d ' ')
ALL_COUNT=$(wc -l <"$ALL_TUP" | tr -d ' ')
KEPT_COUNT=$(wc -l <"$KEPT_TUP" | tr -d ' ')

echo "[+] Total unique tuples (all inputs):  $ALL_COUNT" >&2
echo "[+] Total unique tuples (kept only):   $KEPT_COUNT" >&2
echo "[+] Missing tuples (all - kept):       $MISS_COUNT" >&2

if [[ "$MISS_COUNT" -eq 0 ]]; then
  echo "[OK] No missing tuples; minimized corpus covers full tuple set." >&2
  rm -f "$ALL_TUP" "$KEPT_TUP" "$MISS_TUP"
  exit 0
fi

echo "[!] Missing tuples detected. First 20:" >&2
head -n 20 "$MISS_TUP" >&2 || true

echo "[*] Locating discarded inputs that contribute missing tuples..." >&2
(
  cd "$OUT_DIR"
  shopt -s nullglob
  for tf in .traces/*; do
    [[ -f "$tf" ]] || continue
    base="$(basename "$tf")"

    # Skip traces for kept files.
    if [[ -f "./$base" ]]; then
      continue
    fi

    if grep -Fqf "$MISS_TUP" "$tf"; then
      # Optional: print how many missing tuples this file has.
      cnt=$(grep -Ff "$MISS_TUP" "$tf" | wc -l | tr -d ' ')
      echo "$base\t$cnt"
    fi
  done
) | sort -k2,2nr | head -n 50 | awk 'BEGIN{FS="\t"} {printf("  %s  (missing tuples inside: %s)\n", $1, $2)}' >&2

echo "[!] Hint: if coverage is flaky, try increasing -t and/or running multiple times and taking union." >&2

echo "[*] Tuple files kept at:" >&2
echo "    $ALL_TUP" >&2
echo "    $KEPT_TUP" >&2
echo "    $MISS_TUP" >&2

echo "[FAIL] Missing tuples; minimized corpus does NOT cover full tuple set." >&2
exit 2
