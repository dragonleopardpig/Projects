# Sourced by interactive Bash. Keep pipeline options local to this invocation.
rebuild() {
  local logfile rebuild_status answer
  logfile=$(mktemp /tmp/nixos-rebuild-error.XXXXXX) || return
  if (set -o pipefail; "$HOME/Projects/NixOS/rebuild.sh" "$@" 2>&1 | tee "$logfile"); then
    rm -f "$logfile"
    return 0
  else
    rebuild_status=$?
  fi

  printf '\n[!] Rebuild failed (exit %s). Hand over to Antigravity to diagnose and fix? [Y/n] ' "$rebuild_status"
  read -r answer || answer=n
  if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
    agy --dangerously-skip-permissions -i "NixOS rebuild failed with the following error output:

$(cat "$logfile")

Please diagnose the issue in $HOME/Projects/NixOS, explain what went wrong, and propose a fix." || true
  fi
  rm -f "$logfile"
  return "$rebuild_status"
}
