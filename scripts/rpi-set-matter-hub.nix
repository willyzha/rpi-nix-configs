{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-matter-hub" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-matter-hub [URL] [TOKEN])" >&2
    exit 1
  fi

  ENV_FILE="/persist/secrets/matter-hub.env"
  DATA_DIR="/persist/docker/ha-matter-hub"
  DEFAULT_URL="http://192.168.1.8:8123"

  mkdir -p /persist/secrets
  chmod 700 /persist/secrets
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  # 1. Load current values if present
  CURRENT_URL=""
  CURRENT_TOKEN=""
  if [ -f "$ENV_FILE" ]; then
    CURRENT_URL=$(grep -E '^HAMH_HOME_ASSISTANT_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r\n"' || true)
    CURRENT_TOKEN=$(grep -E '^HAMH_HOME_ASSISTANT_ACCESS_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r\n"' || true)
  fi

  # Fallback URL if empty or placeholder
  if [ -z "$CURRENT_URL" ] || [[ "$CURRENT_URL" =~ homeassistant\.local ]]; then
    CURRENT_URL="$DEFAULT_URL"
  fi

  # 2. Parse arguments or prompt interactively
  URL=""
  TOKEN=""

  if [ $# -gt 0 ]; then
    # Mode A: Non-interactive arguments passed (arg 1: URL, arg 2: token)
    URL="$1"
    if [ $# -gt 1 ]; then
      TOKEN="$2"
    else
      TOKEN="$CURRENT_TOKEN"
    fi
  else
    # Mode B: Interactive wizard
    echo "=================================================="
    echo "  Home Assistant Matter Hub Setup Wizard          "
    echo "=================================================="
    echo "This script configures your Home Assistant URL"
    echo "and Long-Lived Access Token in persistent storage (/persist)."
    echo ""

    read -rp "Enter Home Assistant URL [$CURRENT_URL]: " INPUT_URL
    URL="''${INPUT_URL:-$CURRENT_URL}"

    PROMPT_TOKEN="Enter Home Assistant Long-Lived Access Token"
    if [ -n "$CURRENT_TOKEN" ]; then
      MASKED_TOKEN="''${CURRENT_TOKEN:0:7}...''${CURRENT_TOKEN: -4}"
      PROMPT_TOKEN="$PROMPT_TOKEN [current: $MASKED_TOKEN, press Enter to keep]"
    fi
    read -rsp "$PROMPT_TOKEN: " INPUT_TOKEN
    echo ""
    TOKEN="''${INPUT_TOKEN:-$CURRENT_TOKEN}"
  fi

  if [ -z "$URL" ]; then
    echo "Error: Home Assistant URL cannot be empty." >&2
    exit 1
  fi

  if [ -z "$TOKEN" ]; then
    echo "Error: Home Assistant Access Token cannot be empty." >&2
    exit 1
  fi

  # 3. Write persistent environment file
  cat <<EOF > "$ENV_FILE"
HAMH_HOME_ASSISTANT_URL=$URL
HAMH_HOME_ASSISTANT_ACCESS_TOKEN=$TOKEN
EOF
  chmod 600 "$ENV_FILE"
  echo "==> Stored URL and Access Token in $ENV_FILE"

  # 4. Commit changes to physical SD card
  if command -v rpi-persist-save >/dev/null 2>&1; then
    echo "==> Committing secrets and data directory to physical SD card (/persist-raw)..."
    rpi-persist-save secrets/matter-hub.env docker/ha-matter-hub
  fi

  # 5. Restart docker-matter-hub service if present
  if systemctl list-unit-files | grep -q docker-matter-hub.service; then
    echo "==> Restarting docker-matter-hub.service to apply credentials..."
    systemctl reset-failed docker-matter-hub.service 2>/dev/null || true
    systemctl restart docker-matter-hub.service 2>/dev/null || true

    echo "==> Waiting for Matter Hub to start and listen on port 8482..."
    for i in {1..30}; do
      if ss -tlpn 2>/dev/null | grep -q :8482; then
        echo "  [✓] Matter Hub is up and running!"
        break
      fi
      sleep 2
    done

    echo ""
    echo "--------------------------------------------------"
    echo " Live Service Execution Log:"
    echo "--------------------------------------------------"
    journalctl -u docker-matter-hub.service -n 12 --no-pager || true
    echo "--------------------------------------------------"
  fi

  # Detect node IP and hostname for user convenience
  NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
  NODE_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null || echo "kir-pi-primary")

  echo ""
  echo "==> Matter Hub configuration successfully saved and persisted!"
  echo "Web UI is available at:"
  echo "  - http://$NODE_IP:8482"
  echo "  - http://$NODE_HOST.local:8482"
''
