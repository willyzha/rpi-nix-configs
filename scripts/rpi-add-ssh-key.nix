{ pkgs }:

pkgs.writeShellScriptBin "rpi-add-ssh-key" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-add-ssh-key)" >&2
    exit 1
  fi

  show_help() {
    cat <<'EOF'
Usage: sudo rpi-add-ssh-key [options] [PUBLIC_KEY] [USER]

Add an authorized SSH public key locally without committing to Git/GitHub.
Keys are saved in /persist/etc/ssh/authorized_keys.d/<user> and survive
reboots, rebuilds, and power cycles.

Arguments:
  PUBLIC_KEY   The public SSH key string (e.g. "ssh-ed25519 AAAAC3... user@host")
  USER         Target system user (default: root)

Options:
  -f, --file FILE   Read public key from a file
  -u, --user USER   Target system user (default: root)
  -l, --list        List all local persistent authorized keys
  -h, --help        Show this help message

Interactive:
  Run 'sudo rpi-add-ssh-key' without arguments to be prompted interactively.
EOF
  }

  KEY_DIR="/persist/etc/ssh/authorized_keys.d"
  TARGET_USER="root"
  KEY=""
  KEY_FILE=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -l|--list)
        echo "================================================================"
        echo "   Local Persistent Authorized Keys (/persist/etc/ssh)          "
        echo "================================================================"
        if [ -d "$KEY_DIR" ] && [ -n "$(ls -A "$KEY_DIR" 2>/dev/null)" ]; then
          for f in "$KEY_DIR"/*; do
            [ -f "$f" ] || continue
            local_user=$(basename "$f")
            echo "User: $local_user"
            while IFS= read -r line || [ -n "$line" ]; do
              [ -n "$line" ] || continue
              echo "  - $line"
            done < "$f"
          done
        else
          echo "  (No local persistent keys installed yet)"
        fi
        exit 0
        ;;
      -f|--file)
        shift
        KEY_FILE="''${1:-}"
        ;;
      -u|--user)
        shift
        TARGET_USER="''${1:-root}"
        ;;
      *)
        if [ -z "$KEY" ]; then
          KEY="$1"
        else
          TARGET_USER="$1"
        fi
        ;;
    esac
    shift
  done

  if [ -n "$KEY_FILE" ]; then
    if [ ! -f "$KEY_FILE" ]; then
      echo "Error: Key file '$KEY_FILE' does not exist." >&2
      exit 1
    fi
    KEY=$(cat "$KEY_FILE")
  fi

  if [ -z "$KEY" ]; then
    echo "================================================================"
    echo "   Add Local Persistent SSH Key (Not Tracked in Git)            "
    echo "================================================================"
    echo
    read -rp "Target User [root/pi] (default: root): " input_user
    if [ -n "$input_user" ]; then
      TARGET_USER="$input_user"
    fi

    echo "Paste the public SSH key (e.g. ssh-ed25519 AAAAC3...):"
    read -rp "> " KEY
    echo
  fi

  # Trim leading/trailing whitespace
  KEY=$(echo "$KEY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  if [ -z "$KEY" ]; then
    echo "Error: No SSH key provided." >&2
    exit 1
  fi

  # Basic validation of SSH public key format
  case "$KEY" in
    ssh-ed25519*|ssh-rsa*|ecdsa-sha2-nistp*|sk-ssh-ed25519*|sk-ecdsa-sha2-nistp*)
      ;;
    *)
      echo "Warning: Key does not start with a standard SSH key type (ssh-ed25519, ssh-rsa, etc.)." >&2
      read -rp "Proceed anyway? [y/N]: " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted." >&2
        exit 1
      fi
      ;;
  esac

  USER_KEY_FILE="$KEY_DIR/$TARGET_USER"

  mkdir -p "$KEY_DIR"
  chmod 755 "$KEY_DIR"
  touch "$USER_KEY_FILE"
  chmod 600 "$USER_KEY_FILE"
  chown root:root "$USER_KEY_FILE"

  # Check if key is already installed
  if grep -qF "$KEY" "$USER_KEY_FILE" 2>/dev/null; then
    echo "Notice: This key is already present in $USER_KEY_FILE."
  else
    echo "$KEY" >> "$USER_KEY_FILE"
    echo "  [ADDED] Public key appended to $USER_KEY_FILE"
  fi

  # Immediately commit through OverlayFS down to physical SD card
  if command -v rpi-persist-save >/dev/null 2>&1; then
    echo "==> Committing to physical SD card..."
    rpi-persist-save ssh
  fi

  echo
  echo "==> SSH key successfully configured for user '$TARGET_USER'!"
  echo "    Keys in /persist/etc/ssh/authorized_keys.d/ survive all future reboots"
  echo "    and NixOS rebuilds, and will never be tracked by or pushed to GitHub."
''
