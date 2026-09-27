{ pkgs }:

pkgs.writeShellScriptBin "rpi-persist-save" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-persist-save [paths...])" >&2
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

  save_path() {
    local TARGET="$1"
    # Normalize target relative to persist
    TARGET="''${TARGET#/persist/}"
    TARGET="''${TARGET#/persist-raw/}"
    TARGET="''${TARGET#/}"

    local SRC="/persist/$TARGET"
    local DEST="/persist-raw/$TARGET"

    if [ ! -e "$SRC" ]; then
      echo "Warning: '$SRC' does not exist in /persist. Skipping." >&2
      return 0
    fi

    if [ -d "$SRC" ]; then
      echo "==> Saving directory '/persist/$TARGET' to SD card (/persist-raw)..."
      mkdir -p "$DEST"
      ${pkgs.rsync}/bin/rsync -a --delete --exclude-special "$SRC/" "$DEST/"
    else
      echo "==> Saving file '/persist/$TARGET' to SD card (/persist-raw)..."
      mkdir -p "$(dirname "$DEST")"
      ${pkgs.rsync}/bin/rsync -a --exclude-special "$SRC" "$DEST"
    fi
  }

  if [ $# -gt 0 ]; then
    for arg in "$@"; do
      save_path "$arg"
    done
  else
    echo "==> Scanning for unsaved changes in /persist overlay..."
    # First process any deleted files (OverlayFS whiteout character devices)
    find "$UPPER_DIR" -type c 2>/dev/null | while read -r wh; do
      rel="''${wh#"$UPPER_DIR/"}"
      if [ -e "/persist-raw/$rel" ]; then
        echo "  [DELETED] /persist-raw/$rel"
        rm -rf "/persist-raw/$rel"
      fi
    done

    # Check for new or modified files
    NEW_OR_MODIFIED=$(find "$UPPER_DIR" -mindepth 1 ! -type c 2>/dev/null || true)
    if [ -z "$NEW_OR_MODIFIED" ]; then
      echo "No unsaved changes in /persist overlay."
    else
      echo "==> Detected modified/created files in /persist overlay:"
      (cd "$UPPER_DIR" && find . -type f -o -type l 2>/dev/null | sed 's|^\./|  - /persist/|')
      echo "==> Syncing all overlay changes down to /persist-raw (SD card)..."
      ${pkgs.rsync}/bin/rsync -a --exclude-special "$UPPER_DIR/" "/persist-raw/"
    fi
  fi

  sync
  echo "==> Changes successfully committed to physical SD card storage (/persist-raw)."
''
