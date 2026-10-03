{ pkgs }:

pkgs.writeShellScriptBin "rpi-check-update" ''
  #!/usr/bin/env bash
  set -euo pipefail

  JSON_OUTPUT=0
  if [ "''${1:-}" = "--json" ]; then
    JSON_OUTPUT=1
  fi

  REPO_URL="https://github.com/willyzha/rpi-nix-configs.git"

  if [ "$JSON_OUTPUT" -eq 0 ]; then
    echo "==> Checking latest GitHub commit for $REPO_URL..."
  fi

  # Query latest commit SHA directly via git wire protocol (instant ~0.3s, zero Nix overhead)
  LATEST_REV=""
  for _ in 1 2 3; do
    LATEST_REV=$(${pkgs.coreutils}/bin/timeout 15 ${pkgs.git}/bin/git ls-remote "$REPO_URL" HEAD 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo "")
    if [ -n "$LATEST_REV" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "$LATEST_REV" ]; then
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      echo '{"error": "Failed to connect to repository"}'
    else
      echo "Error: Failed to connect to $REPO_URL. Check network connectivity." >&2
    fi
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

  UPDATE_AVAILABLE=false
  if [ -n "$CLEAN_CURRENT" ] && [ "$CLEAN_CURRENT" = "$LATEST_REV" ]; then
    UPDATE_AVAILABLE=false
  else
    UPDATE_AVAILABLE=true
  fi

  INSTALLED_SHORT="''${CURRENT_REV:0:12}"
  LATEST_SHORT="''${LATEST_REV:0:12}"
  [ -z "$INSTALLED_SHORT" ] && INSTALLED_SHORT="unknown"

  CACHE_FILE="/run/rpi-check-update.cache"
  JSON_DATA=$(${pkgs.jq}/bin/jq -n \
    --argjson update "$UPDATE_AVAILABLE" \
    --arg inst "$INSTALLED_SHORT" \
    --arg late "$LATEST_SHORT" \
    --arg inst_full "$CURRENT_REV" \
    --arg late_full "$LATEST_REV" \
    --arg checked "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '{
      update_available: $update,
      installed_version: $inst,
      latest_version: $late,
      installed_revision: $inst_full,
      latest_revision: $late_full,
      last_checked: $checked
    }')

  # Save cache in /run (tmpfs in RAM - 0 SD card writes)
  if [ -d /run ]; then
    {
      date +%s
      echo "$JSON_DATA"
    } > "$CACHE_FILE.tmp" 2>/dev/null && mv -f "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null || true
  fi

  if [ "$JSON_OUTPUT" -eq 1 ]; then
    echo "$JSON_DATA"
    exit 0
  fi

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

  if [ "$UPDATE_AVAILABLE" = "false" ]; then
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
