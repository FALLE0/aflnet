#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible wrapper.
#
# The maintained implementation (including -r/-n/-S stable mode) lives in tools/check_cmin_tuples.sh.
# Some users call this script from PATH or repo root; delegate to avoid having
# two divergent copies.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/tools/check_cmin_tuples.sh" "$@"