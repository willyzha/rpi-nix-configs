{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-swag" ''
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-swag)" >&2
    exit 1
  fi

  echo "=========================================="
  echo "    SWAG Reverse Proxy Setup Wizard       "
  echo "=========================================="
  echo "All inputs are stored locally in /persist and NEVER tracked by Git."
  echo

  # 1. Domain URL
  CURRENT_URL=""
  if [ -f /persist/secrets/swag.env ]; then
    CURRENT_URL=$(grep -E '^URL=' /persist/secrets/swag.env | cut -d= -f2- || true)
  fi
  read -rp "Enter Root Domain (e.g. example.com) [$CURRENT_URL]: " INPUT_URL
  URL="''${INPUT_URL:-$CURRENT_URL}"
  if [ -z "$URL" ]; then
    echo "Error: Domain URL cannot be empty." >&2
    exit 1
  fi

  # 2. Contact Email
  CURRENT_EMAIL=""
  if [ -f /persist/secrets/swag.env ]; then
    CURRENT_EMAIL=$(grep -E '^EMAIL=' /persist/secrets/swag.env | cut -d= -f2- || true)
  fi
  read -rp "Enter Email for Let's Encrypt [$CURRENT_EMAIL]: " INPUT_EMAIL
  EMAIL="''${INPUT_EMAIL:-$CURRENT_EMAIL}"
  if [ -z "$EMAIL" ]; then
    echo "Error: Email cannot be empty." >&2
    exit 1
  fi

  mkdir -p /persist/secrets
  cat <<EOF > /persist/secrets/swag.env
URL=$URL
EMAIL=$EMAIL
EOF
  chmod 600 /persist/secrets/swag.env
  echo "==> Stored URL and EMAIL in /persist/secrets/swag.env"

  # 3. Cloudflare API Token
  CF_DIR="/persist/docker/swag/config/dns-conf"
  CF_INI="$CF_DIR/cloudflare.ini"
  mkdir -p "$CF_DIR"
  CURRENT_TOKEN=""
  if [ -f "$CF_INI" ]; then
    CURRENT_TOKEN=$(grep -E 'dns_cloudflare_api_token' "$CF_INI" | awk -F= '{gsub(/[ \t]/,"",$2); print $2}' || true)
  fi

  PROMPT_TEXT="Enter Cloudflare API Token"
  if [ -n "$CURRENT_TOKEN" ]; then
    PROMPT_TEXT="$PROMPT_TEXT [press Enter to keep existing token]"
  fi
  read -rsp "$PROMPT_TEXT: " INPUT_TOKEN
  echo

  TOKEN="''${INPUT_TOKEN:-$CURRENT_TOKEN}"
  if [ -n "$TOKEN" ]; then
    cat <<EOF > "$CF_INI"
dns_cloudflare_api_token = $TOKEN
EOF
    chmod 600 "$CF_INI"
    echo "==> Stored Cloudflare token in $CF_INI"
  fi

  # 4. Proxy Configurations Check & Reminder
  PROXY_CONFS_DIR="/persist/docker/swag/config/nginx/proxy-confs"
  mkdir -p "$PROXY_CONFS_DIR"
  echo
  echo "=========================================="
  echo "    Proxy Configurations (Nginx)          "
  echo "=========================================="
  CONF_COUNT=$(find "$PROXY_CONFS_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)
  if [ "$CONF_COUNT" -eq 0 ]; then
    echo "NOTICE: No active proxy configuration files found in:"
    echo "  $PROXY_CONFS_DIR"
    echo
    echo "REMINDER: Place your *.subdomain.conf files in that directory to reverse proxy your services."
    echo "Example:"
    echo "  sudo cp /path/to/my-service.subdomain.conf $PROXY_CONFS_DIR/"
    echo "Or copy from pi-primary:"
    echo "  sudo scp pi@192.168.1.11:$PROXY_CONFS_DIR/*.subdomain.conf $PROXY_CONFS_DIR/"
    echo
  else
    echo "Found $CONF_COUNT active proxy configuration file(s) in:"
    echo "  $PROXY_CONFS_DIR"
    ls -1 "$PROXY_CONFS_DIR"/*.conf 2>/dev/null | sed 's/^/  - /'
  fi

  # 5. Ensure logrotate stub files exist (required by Docker volume mounts to prevent exit status 125)
  LOGROTATE_DIR="/persist/docker/swag/logrotate"
  mkdir -p "$LOGROTATE_DIR/logrotate.d"
  touch "$LOGROTATE_DIR/logrotate.conf" \
        "$LOGROTATE_DIR/logrotate.d/fail2ban" \
        "$LOGROTATE_DIR/logrotate.d/lerotate" \
        "$LOGROTATE_DIR/logrotate.d/nginx" \
        "$LOGROTATE_DIR/logrotate.d/php-fpm"

  echo
  echo "==> SWAG credentials and volume stubs successfully created in /persist."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    echo "==> Committing SWAG secrets and proxy config to SD card..."
    rpi-persist-save secrets/swag.env docker/swag/config/dns-conf docker/swag/config/nginx/proxy-confs
  fi
  if systemctl list-unit-files | grep -q docker-swag.service; then
    echo "==> Resetting failed units and restarting docker-swag.service..."
    systemctl reset-failed docker-swag.service 2>/dev/null || true
    systemctl restart docker-swag.service
    echo
    echo "=========================================="
    echo "    Service Commands & Monitoring         "
    echo "=========================================="
    echo "1. On first run, SWAG requests wildcard SSL certificates via Cloudflare."
    echo "   Monitor live startup and certificate generation with:"
    echo "     sudo docker logs -f swag"
    echo
    echo "2. Once the container is running and initialized, reload Nginx after config edits with:"
    echo "     sudo docker exec swag nginx -s reload"
    echo
    echo "3. To restart or start the SWAG service at any time:"
    echo "     sudo systemctl restart docker-swag"
    echo "=========================================="
  fi
''
