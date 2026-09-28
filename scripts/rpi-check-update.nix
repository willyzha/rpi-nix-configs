{ pkgs }:

pkgs.writeShellScriptBin "rpi-check-update" ''
  #!/usr/bin/env bash
  set -euo pipefail

  REPO_URL="https://github.com/willyzha/rpi-nix-configs.git"

  echo "==> Checking latest GitHub commit for $REPO_URL..."

  # Query latest commit SHA directly via git wire protocol (instant ~0.3s, zero Nix overhead)
  LATEST_REV=$(${pkgs.git}/bin/git ls-remote "$REPO_URL" HEAD 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo "")

  if [ -z "$LATEST_REV" ]; then
    echo "Error: Failed to connect to $REPO_URL. Check network connectivity." >&2
    exit 2
  fi

  # Read running system's baked-in configuration revision
  CURRENT_REV=""
  if [ -f /run/current-system/configuration-revision ]; then
    CURRENT_REV=$(cat /run/current-system/configuration-revision | tr -d '\r\n[:space:]')
  elif command -v nixos-version >/dev/null 2>&1; then
    CURRENT_REV=$(nixos-version --configuration-revision 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
  fi

  CLEAN_CURRENT="''${CURRENT_REV%-dirty}"

  echo ""
  if [ -n "$CURRENT_REV" ]; then
    if [[ "$CURRENT_REV" == *"-dirty" ]]; then
      echo "Running System: ''${CURRENT_REV:0:12} ($CURRENT_REV) [local modifications]"
    else
      echo "Running System: ''${CURRENT_REV:0:12} ($CURRENT_REV)"
    fi
  else
    echo "Running System: (generation built before commit tracking was enabled)"
  fi
  echo "Latest GitHub:  ''${LATEST_REV:0:12} ($LATEST_REV)"
  echo ""

  if [ -n "$CLEAN_CURRENT" ] && [ "$CLEAN_CURRENT" = "$LATEST_REV" ]; then
    if [[ "$CURRENT_REV" == *"-dirty" ]]; then
      echo "✅ System is based on the latest GitHub commit (with local uncommitted modifications)!"
    else
      echo "✅ System is up to date with the latest GitHub commit!"
    fi
    exit 0
  else
    echo "⚠️ Update available on GitHub!"
    echo "   To apply this update from your host, run:"
    echo "   ./docker-rebuild.sh $(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
    exit 1
  fi
''
