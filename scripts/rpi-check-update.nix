{ pkgs }:

pkgs.writeShellScriptBin "rpi-check-update" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Ensure nix can create evaluation cache in RAM even when root / is read-only
  export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-/tmp/.cache}"

  SHOW_DIFF=false
  HOST=""

  for arg in "$@"; do
    case "$arg" in
      -d|--diff)
        SHOW_DIFF=true
        ;;
      -h|--help)
        echo "Usage: rpi-check-update [-d|--diff] [hostname]"
        echo "Checks if the current running system is up to date with the latest GitHub configuration."
        exit 0
        ;;
      *)
        HOST="$arg"
        ;;
    esac
  done

  HOST="''${HOST:-$(hostname)}"
  FLAKE_REF="github:willyzha/rpi-nix-configs"

  echo "==> Checking latest GitHub configuration for $HOST..."

  CURRENT=$(${pkgs.coreutils}/bin/readlink -f /run/current-system)
  LATEST=$(${pkgs.nix}/bin/nix path-info "$FLAKE_REF#nixosConfigurations.$HOST.config.system.build.toplevel" --refresh 2>/dev/null || true)

  if [ -z "$LATEST" ]; then
    echo "Error: Failed to query latest build from $FLAKE_REF for host '$HOST'." >&2
    echo "Check network connectivity to github.com." >&2
    exit 2
  fi

  echo ""
  echo "Running System: $CURRENT"
  echo "Latest GitHub:  $LATEST"
  echo ""

  if [ "$CURRENT" = "$LATEST" ]; then
    echo "✅ System is up to date with the latest GitHub changes!"
    exit 0
  else
    echo "⚠️ Update available on GitHub!"
    echo "   To apply this update, run:"
    echo "   sudo rpi-rebuild boot $FLAKE_REF#$HOST"

    if [ "$SHOW_DIFF" = "true" ]; then
      echo ""
      echo "==> File diffs (/etc):"
      ${pkgs.diffutils}/bin/diff -ru "$CURRENT/etc" "$LATEST/etc" 2>/dev/null || true
    else
      echo ""
      echo "   Tip: Pass '--diff' to inspect file changes: rpi-check-update --diff"
    fi
    exit 1
  fi
''
