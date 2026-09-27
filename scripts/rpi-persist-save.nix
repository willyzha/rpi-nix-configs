{ pkgs }:

pkgs.writeShellScriptBin "rpi-persist-save" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "$EUID" -ne 0 ]; then
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
  # Intentionally excludes volatile runtime state like AdGuard query logs (data/)
  # and SSH host keys (already initialized on first boot) to prevent SD card wear.
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
      echo "  [DELETED] /persist-raw/$TARGET"
      rm -rf "$DEST"
      return 0
    fi

    # Handle whiteout deletions within directory targets
    if [ -d "$UPPER_PATH" ]; then
      find "$UPPER_PATH" -type c 2>/dev/null | while read -r wh; do
        local rel="''${wh#"$UPPER_DIR/"}"
        if [ -e "/persist-raw/$rel" ]; then
          echo "  [DELETED] /persist-raw/$rel"
          rm -rf "/persist-raw/$rel"
        fi
      done
    fi

    if [ -d "$SRC" ]; then
      echo "  [SAVE DIR]  /persist/$TARGET -> /persist-raw/$TARGET"
      mkdir -p "$DEST"
      ${pkgs.rsync}/bin/rsync -a --delete --exclude-special "$SRC/" "$DEST/"
    else
      echo "  [SAVE FILE] /persist/$TARGET -> /persist-raw/$TARGET"
      mkdir -p "$(dirname "$DEST")"
      ${pkgs.rsync}/bin/rsync -a --exclude-special "$SRC" "$DEST"
    fi
  }

  SAVED_ANY=false

  if [ $# -gt 0 ]; then
    # Mode 1: Explicit targets provided — save ONLY the requested files/directories
    for arg in "$@"; do
      while IFS= read -r expanded; do
        [ -n "$expanded" ] || continue
        save_single_path "$expanded"
        SAVED_ANY=true
      done < <(expand_target "$arg")
    done
  else
    # Mode 2: No arguments — targeted scan of ONLY allowed whitelist items that changed
    echo "==> Running targeted scan of expected persistent state..."
    for w in "''${WHITELIST[@]}"; do
      if [ -e "$UPPER_DIR/$w" ] || [ -c "$UPPER_DIR/$w" ]; then
        save_single_path "$w"
        SAVED_ANY=true
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
      echo
      echo "==> Unregistered modifications detected in /persist overlay (ignored):"
      for u in "''${UNREGISTERED[@]}"; do
        echo "  [IGNORED] /persist/$u (temporary in RAM, NOT saved to SD card)"
      done
      echo "  (To explicitly save an unlisted path, run: sudo rpi-persist-save <path>)"
    fi
  fi

  if [ "$SAVED_ANY" = true ]; then
    sync
    echo "==> Targeted changes successfully committed to physical SD card (/persist-raw)."
  else
    echo "==> No pending changes to expected persistent targets."
  fi
''
