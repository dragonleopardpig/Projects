#!/usr/bin/env bash
set -euo pipefail
script=$(realpath "${1:-$(dirname "$0")/rebuild-agent.sh}")
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/Projects/NixOS"
cat > "$temporary/Projects/NixOS/rebuild.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fixture rebuild output\n'
exit "${FIXTURE_EXIT:-0}"
EOF
chmod +x "$temporary/Projects/NixOS/rebuild.sh"
export HOME="$temporary"
export HANDOFF_FILE="$temporary/handoff"
agy() { printf '%s\n' "$@" > "$HANDOFF_FILE"; return "${AGENT_EXIT:-0}"; }
export -f agy
source "$script"

# Success, failure with declined handoff, accepted handoff, and failed agent.
# Run each both with and without caller pipefail; the helper must not change it.
for option in enabled disabled; do
  if [[ $option == enabled ]]; then set -o pipefail; else set +o pipefail; fi
  export FIXTURE_EXIT=0
  rebuild boot CRUCIAL-SSD > "$temporary/output"
  [[ ! -e $HANDOFF_FILE ]]
  export FIXTURE_EXIT=42
  if rebuild boot CRUCIAL-SSD > "$temporary/output" <<< n; then exit 1; else status=$?; fi
  [[ $status == 42 && ! -e $HANDOFF_FILE ]]
  if rebuild boot CRUCIAL-SSD > "$temporary/output" <<< y; then exit 1; else status=$?; fi
  [[ $status == 42 ]]
  rg -q -- '--dangerously-skip-permissions' "$HANDOFF_FILE"
  rg -q 'fixture rebuild output' "$HANDOFF_FILE"
  export AGENT_EXIT=9
  if rebuild boot CRUCIAL-SSD > "$temporary/output" <<< y; then exit 1; else status=$?; fi
  [[ $status == 42 ]]
  if [[ $option == enabled ]]; then [[ -o pipefail ]]; else [[ ! -o pipefail ]]; fi
  unset AGENT_EXIT
  rm "$HANDOFF_FILE"
done
printf 'Rebuild handoff: success, decline, accept, agent failure and exit codes passed.\n'
