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
    CURRENT_REV=$(cat /run/current-system/configuration-revision)
  fi

  echo ""
  if [ -n "$CURRENT_REV" ]; then
    echo "Running System: ''${CURRENT_REV:0:12} ($CURRENT_REV)"
  else
    echo "Running System: (generation built before commit tracking was enabled)"
  fi
  echo "Latest GitHub:  ''${LATEST_REV:0:12} ($LATEST_REV)"
  echo ""

  if [ -n "$CURRENT_REV" ] && [ "$CURRENT_REV" = "$LATEST_REV" ]; then
    echo "✅ System is up to date with the latest GitHub commit!"
    exit 0
  else
    echo "⚠️ Update available on GitHub!"
    echo "   To apply this update, run:"
    echo "   sudo rpi-rebuild"
    exit 1
  fi
''
