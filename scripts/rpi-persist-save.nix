{ pkgs }:

pkgs.writeShellScriptBin "rpi-persist-save" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-persist-save [targets...])" >&2
    exit 1
  fi

  UPPER_DIR="/run/persist-overlay/upper"
  if [ ! -d "$UPPER_DIR" ]; then
    echo "Notice: Overlay directory $UPPER_DIR does not exist (OverlayFS not active?)."
    exit 0
  fi

  if ! mountpoint -q /persist-raw; then
    echo "Error: /persist-raw is not mounted." >&2
    exit 1
  fi

  # Strict whitelist of expected persistent paths (used when no arguments are given)
  WHITELIST=(
    "secrets"
    "docker/swag/config/etc/letsencrypt"
    "docker/swag/config/nginx/proxy-confs"
    "docker/swag/config/dns-conf"
  )

  # Expand target aliases and normalize paths
  expand_target() {
    local T="$1"
    case "$T" in
      certs|certificates|ssl)
        echo "docker/swag/config/etc/letsencrypt"
        ;;
      swag|swag-config)
        echo "docker/swag/config/nginx/proxy-confs"
        echo "docker/swag/config/dns-conf"
        echo "secrets/swag.env"
        ;;
      passwords)
        echo "secrets/nut-monuser-password"
        echo "secrets/keepalived-auth.conf"
        echo "secrets/restic-password"
        ;;
      secrets)
        echo "secrets"
        ;;
      tailscale)
        echo "var/lib/tailscale"
        ;;
      adguard|adguard-config)
        echo "var/lib/AdGuardHome/AdGuardHome.yaml"
        ;;
      ssh)
        echo "etc/ssh"
        ;;
      *)
        T="''${T#/persist/}"
        T="''${T#/persist-raw/}"
        T="''${T#/}"
        echo "$T"
        ;;
    esac
  }

  COPIED_ANY=false

  save_single_path() {
    local TARGET="$1"
    TARGET="''${TARGET#/persist/}"
    TARGET="''${TARGET#/persist-raw/}"
    TARGET="''${TARGET#/}"
    TARGET="''${TARGET%/}"

    local SRC="/persist/$TARGET"
    local DEST="/persist-raw/$TARGET"
    local UPPER_PATH="$UPPER_DIR/$TARGET"

    if [ ! -e "$SRC" ] && [ ! -c "$UPPER_PATH" ]; then
      echo "  [SKIP] '/persist/$TARGET' does not exist."
      return 0
    fi

    # Handle deletion of a target file/folder (whiteout device in overlay)
    if [ -c "$UPPER_PATH" ]; then
      echo "  [DELETED] /persist-raw/$TARGET (reflecting overlay deletion)"
      rm -rf "$DEST"
      COPIED_ANY=true
      return 0
    fi

    # Handle whiteout deletions within directory targets
    if [ -d "$UPPER_PATH" ]; then
      while read -r wh; do
        [ -n "$wh" ] || continue
        local rel="''${wh#"$UPPER_DIR/"}"
        if [ -e "/persist-raw/$rel" ]; then
          echo "  [DELETED] /persist-raw/$rel (reflecting overlay deletion)"
          rm -rf "/persist-raw/$rel"
          COPIED_ANY=true
        fi
      done < <(find "$UPPER_PATH" -type c 2>/dev/null || true)
    fi

    if [ -d "$SRC" ]; then
      mkdir -p "$DEST"
      # Run rsync with itemize-changes (-i) to detect actual differences
      local CHANGES
      CHANGES=$(${pkgs.rsync}/bin/rsync -a -i --delete --no-specials --no-devices "$SRC/" "$DEST/" 2>&1 || true)
      if [ -n "$CHANGES" ]; then
        echo "  [SAVED DIR]  /persist/$TARGET -> /persist-raw/$TARGET"
        COPIED_ANY=true
      else
        echo "  [IDENTICAL]  /persist/$TARGET matches SD card (no copy needed)"
      fi
    else
      mkdir -p "$(dirname "$DEST")"
      local CHANGES
      CHANGES=$(${pkgs.rsync}/bin/rsync -a -i --no-specials --no-devices "$SRC" "$DEST" 2>&1 || true)
      if [ -n "$CHANGES" ]; then
        echo "  [SAVED FILE] /persist/$TARGET -> /persist-raw/$TARGET"
        COPIED_ANY=true
      else
        echo "  [IDENTICAL]  /persist/$TARGET matches SD card (no copy needed)"
      fi
    fi
  }

  TARGETS_CHECKED=0

  if [ $# -gt 0 ]; then
    # Mode 1: Explicit targets provided — save ONLY the requested files/directories
    for arg in "$@"; do
      while IFS= read -r expanded; do
        [ -n "$expanded" ] || continue
        TARGETS_CHECKED=$((TARGETS_CHECKED + 1))
        save_single_path "$expanded"
      done < <(expand_target "$arg")
    done
  else
    # Mode 2: No arguments — targeted scan of ONLY allowed whitelist items that changed
    echo "==> Running targeted scan of expected persistent state..."
    for w in "''${WHITELIST[@]}"; do
      if [ -e "$UPPER_DIR/$w" ] || [ -c "$UPPER_DIR/$w" ]; then
        TARGETS_CHECKED=$((TARGETS_CHECKED + 1))
        save_single_path "$w"
      fi
    done

    # Report any unregistered writes in upperdir so user knows they were safely ignored
    UNREGISTERED=()
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      rel="''${item#"$UPPER_DIR/"}"
      is_whitelisted=false
      for w in "''${WHITELIST[@]}"; do
        if [[ "$rel" == "$w"* ]] || [[ "$w" == "$rel"* ]]; then
          is_whitelisted=true
          break
        fi
      done
      if [ "$is_whitelisted" = false ]; then
        UNREGISTERED+=("$rel")
      fi
    done < <(find "$UPPER_DIR" -mindepth 1 -maxdepth 2 2>/dev/null || true)

    if [ "''${#UNREGISTERED[@]}" -gt 0 ]; then
      echo ""
      echo "==> Volatile writes detected in RAM overlay (intentionally not saved to SD card):"
      for u in "''${UNREGISTERED[@]}"; do
        echo "  [EPHEMERAL] /persist/$u"
      done
      echo "  (To explicitly commit an unlisted path, run: sudo rpi-persist-save <path>)"
    fi
  fi

  echo ""
  if [ "$COPIED_ANY" = true ]; then
    sync
    echo "==> Targeted changes successfully committed to physical SD card (/persist-raw)."
  else
    if [ "$TARGETS_CHECKED" -eq 0 ]; then
      echo "==> No changes found in overlay. SD card is already completely up to date (0 bytes written)."
    else
      echo "==> Overlay contents are identical to SD card. Nothing was copied to physical storage (0 bytes written)."
    fi
  fi
''
