#!/usr/bin/env bash
set -euo pipefail
exec python3 "${0%/*}/display-cycle.py" "$@"
