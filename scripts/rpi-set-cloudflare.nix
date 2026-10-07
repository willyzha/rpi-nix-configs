{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-cloudflare" ''
  #!/usr/bin/env bash
  set -euo pipefail

  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-cloudflare [TOKEN] [DOMAINS...])" >&2
    exit 1
  fi

  ENV_FILE="/persist/secrets/cloudflare.env"
  RAW_TOKEN_FILE="/persist/secrets/cloudflare-api-token"
  CF_INI="/persist/docker/swag/config/dns-conf/cloudflare.ini"
  DEFAULT_DOMAINS="example.com *.example.com"

  mkdir -p /persist/secrets
  chmod 700 /persist/secrets

  # 1. Load current values if present
  CURRENT_TOKEN=""
  CURRENT_DOMAINS=""
  if [ -f "$ENV_FILE" ]; then
    CURRENT_TOKEN=$(grep -E '^CLOUDFLARE_API_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r\n"' || true)
    CURRENT_DOMAINS=$(grep -E '^CLOUDFLARE_DOMAINS=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r\n"' || true)
  fi

  # Fallback to SWAG ini or raw token file for token if empty
  if [ -z "$CURRENT_TOKEN" ] && [ -f "$CF_INI" ]; then
    CURRENT_TOKEN=$(grep -E 'dns_cloudflare_api_token' "$CF_INI" | awk -F= '{gsub(/[ \t]/,"",$2); print $2}' || true)
  fi
  if [ -z "$CURRENT_TOKEN" ] && [ -f "$RAW_TOKEN_FILE" ]; then
    CURRENT_TOKEN=$(tr -d '\r\n[:space:]' < "$RAW_TOKEN_FILE" || true)
  fi

  if [ -z "$CURRENT_DOMAINS" ]; then
    CURRENT_DOMAINS="$DEFAULT_DOMAINS"
  fi

  # 2. Parse arguments or prompt interactively
  TOKEN=""
  DOMAINS=""

  if [ $# -gt 0 ]; then
    # Mode A: Non-interactive arguments passed (arg 1: token, arg 2+: domains)
    TOKEN="$1"
    shift
    if [ $# -gt 0 ]; then
      DOMAINS="$*"
    else
      DOMAINS="$CURRENT_DOMAINS"
    fi
  else
    # Mode B: Interactive wizard
    echo "=================================================="
    echo "    Cloudflare Dynamic DNS (DDNS) Setup Wizard   "
    echo "=================================================="
    echo "This script configures and commits your Cloudflare API"
    echo "token and domains to persistent storage (/persist)."
    echo ""

    PROMPT_TOKEN="Enter Cloudflare API Token"
    if [ -n "$CURRENT_TOKEN" ]; then
      MASKED_TOKEN="''${CURRENT_TOKEN:0:7}...''${CURRENT_TOKEN: -4}"
      PROMPT_TOKEN="$PROMPT_TOKEN [current: $MASKED_TOKEN, press Enter to keep]"
    fi
    read -rsp "$PROMPT_TOKEN: " INPUT_TOKEN
    echo ""
    TOKEN="''${INPUT_TOKEN:-$CURRENT_TOKEN}"

    if [ -z "$TOKEN" ]; then
      echo "Error: Cloudflare API token cannot be empty." >&2
      exit 1
    fi

    echo ""
    read -rp "Enter Domain(s) to update [current: $CURRENT_DOMAINS]: " INPUT_DOMAINS
    DOMAINS="''${INPUT_DOMAINS:-$CURRENT_DOMAINS}"
  fi

  if [ -z "$TOKEN" ]; then
    echo "Error: Cloudflare API token cannot be empty." >&2
    exit 1
  fi

  # Clean and normalize domains (replace commas with spaces, collapse extra spaces, trim)
  DOMAINS=$(echo "$DOMAINS" | tr ',' ' ' | tr -s ' ' | xargs)
  if [ -z "$DOMAINS" ]; then
    DOMAINS="$DEFAULT_DOMAINS"
  fi

  # 3. Write persistent environment file
  cat <<EOF > "$ENV_FILE"
CLOUDFLARE_API_TOKEN=$TOKEN
CLOUDFLARE_DOMAINS="$DOMAINS"
EOF
  chmod 600 "$ENV_FILE"
  echo "==> Stored token and domains in $ENV_FILE"

  # 4. Write raw token file for backwards compatibility
  echo -n "$TOKEN" > "$RAW_TOKEN_FILE"
  chmod 600 "$RAW_TOKEN_FILE"

  # 5. Sync token to SWAG certbot ini if SWAG is installed
  if [ -d "$(dirname "$CF_INI")" ] || [ -f "$CF_INI" ]; then
    mkdir -p "$(dirname "$CF_INI")"
    cat <<EOF > "$CF_INI"
dns_cloudflare_api_token = $TOKEN
EOF
    chmod 600 "$CF_INI"
    echo "==> Synchronized Cloudflare token to SWAG ($CF_INI)"
  fi

  # 6. Commit changes to physical SD card
  if command -v rpi-persist-save >/dev/null 2>&1; then
    echo "==> Committing secrets to physical SD card (/persist-raw)..."
    rpi-persist-save secrets/cloudflare.env secrets/cloudflare-api-token docker/swag/config/dns-conf
  fi

  # 7. Restart and test live cloudflare-dyndns service if available
  if systemctl list-unit-files | grep -q cloudflare-dyndns.service; then
    echo "==> Triggering cloudflare-dyndns.service to verify configuration..."
    systemctl reset-failed cloudflare-dyndns.service 2>/dev/null || true
    systemctl restart cloudflare-dyndns.service 2>/dev/null || true
    sleep 2

    echo ""
    echo "--------------------------------------------------"
    echo " Live Service Execution Log:"
    echo "--------------------------------------------------"
    journalctl -u cloudflare-dyndns.service -n 12 --no-pager || true
    echo "--------------------------------------------------"
  fi

  echo ""
  echo "==> Cloudflare DDNS configuration successfully saved and persisted!"
''
