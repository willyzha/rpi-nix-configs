{ pkgs, ... }:

pkgs.writeShellScriptBin "rpi-onboard" ''
  set -e
  
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo rpi-onboard"
    exit 1
  fi
  
  echo "================================================================"
  echo "        Raspberry Pi NixOS Node Onboarding Wizard               "
  echo "================================================================"
  
  HOST="''${HOST:-$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)}"
  echo "Detected Node: $HOST"
  
  # Helper to check if a secret file only contains placeholder/default values
  is_placeholder() {
    local file=$1
    if [ ! -s "$file" ]; then
      return 0
    fi
    if grep -q -E '(changeme|example\.com|192\.168\.1\.X|admin@example\.com|127\.0\.0\.1:51820|homeassistant\.local)' "$file" 2>/dev/null; then
      return 0
    fi
    if grep -q -E 'HAMH_HOME_ASSISTANT_ACCESS_TOKEN=$|WYZE_EMAIL=$' "$file" 2>/dev/null; then
      return 0
    fi
    return 1
  }

  check_secret() {
    local file="$1"
    local desc="$2"
    if [ ! -f "$file" ]; then
      printf "  %-35s : [MISSING]\n" "$desc"
    elif is_placeholder "$file"; then
      printf "  %-35s : [STARTER / PLACEHOLDER]\n" "$desc"
    else
      printf "  %-35s : [CONFIGURED]\n" "$desc"
    fi
  }

  if [[ "''${1:-}" == "--check" || "''${1:-}" == "check" ]]; then
    echo "================================================================"
    echo "       Onboarding Status Check: $HOST                           "
    echo "================================================================"
    echo "Core Secrets:"
    check_secret "/persist/secrets/mqtt.env" "MQTT Credentials"
    if [[ ! "$HOST" =~ ^(ott-pi|pi-remote) ]]; then
      check_secret "/persist/secrets/swag.env" "SWAG Reverse Proxy"
    fi
    check_secret "/persist/secrets/restic-password" "Restic Encryption Password"
    check_secret "/persist/secrets/rclone.conf" "Rclone Backup Config"
    echo ""
    echo "Node-Specific Secrets ($HOST):"
    case "$HOST" in
      kir-pi-primary|pi-primary)
        check_secret "/persist/secrets/keepalived-auth.conf" "Keepalived VRRP Auth"
        check_secret "/persist/secrets/nut-monuser-password" "NUT UPS Password"
        check_secret "/persist/secrets/espresense-tracker.env" "ESPresense Tracker"
        ;;
      kir-pi-secondary|pi-secondary)
        check_secret "/persist/secrets/keepalived-auth.conf" "Keepalived VRRP Auth"
        check_secret "/persist/secrets/wireguard/private.key" "WireGuard Server Key"
        ;;
      ott-pi-primary|ott-pi|pi-remote)
        check_secret "/persist/secrets/wg0.conf" "WireGuard Client Config"
        check_secret "/persist/secrets/matter-hub.env" "Matter Hub Config"
        check_secret "/persist/secrets/wyze-bridge.env" "Wyze Bridge Config"
        ;;
    esac
    echo "================================================================"
    exit 0
  fi

  # Initialize secret directories and remount read-write if necessary
  rpi-init-secrets
  mount -o remount,rw / 2>/dev/null || true
  if mountpoint -q /boot/firmware; then
    mount -o remount,rw /boot/firmware 2>/dev/null || true
  fi

  # Function to prompt text input and save to file
  prompt_file() {
    local file=$1
    local description=$2
    local template=$3
    
    if [ -s "$file" ] && ! is_placeholder "$file"; then
      echo "  [✓] $description ($file) already configured."
      read -p "      Do you want to reconfigure this? (y/N): " reconf
      case $reconf in
        [Yy]* ) ;;
        * ) echo "      Keeping existing configuration."; return 0;;
      esac
    fi
    
    echo ""
    echo "--- Setup: $description ---"
    while true; do
      read -p "Do you want to configure this now? (y/n/skip): " yn
      case $yn in
        [Yy]* ) break;;
        [Nn]*|[Ss]kip ) echo "Skipping $description."; return 0;;
        * ) echo "Please answer yes or no.";;
      esac
    done
    
    if [ ! -s "$file" ]; then
      if [ -n "$template" ]; then
        echo -e "$template" > "$file"
      else
        touch "$file"
      fi
    fi
    chmod 600 "$file"
    
    echo "Opening nano to edit $file..."
    sleep 1
    ${pkgs.nano}/bin/nano "$file"
    
    if [ ! -s "$file" ]; then
      echo "Warning: File is empty. It might not be configured correctly."
    else
      echo "Saved $file."
    fi
  }

  # Function to run an existing wizard script if the target file doesn't exist or is a placeholder
  run_wizard() {
    local file=$1
    local cmd=$2
    local description=$3
    
    if [ -s "$file" ] && ! is_placeholder "$file"; then
      echo "  [✓] $description ($file) already configured."
      read -p "      Do you want to run the $cmd wizard to reconfigure? (y/N): " reconf
      case $reconf in
        [Yy]* ) ;;
        * ) echo "      Keeping existing configuration."; return 0;;
      esac
    fi
    
    echo ""
    echo "--- Setup: $description ---"
    while true; do
      read -p "Do you want to run the $cmd wizard now? (y/n/skip): " yn
      case $yn in
        [Yy]* ) break;;
        [Nn]*|[Ss]kip ) echo "Skipping $description."; return 0;;
        * ) echo "Please answer yes or no.";;
      esac
    done
    
    $cmd
  }

  echo ""
  echo "==> Phase 1: Core System Secrets (All Nodes)"
  
  # User Password (hash is written directly to the host OS, not a secrets file, so we just prompt to run it if they want)
  echo ""
  read -p "Do you want to set the system user password now via rpi-set-password? (y/n): " yn
  if [[ $yn =~ ^[Yy]$ ]]; then
    rpi-set-password
  fi

  # MQTT Monitor
  if [[ "$HOST" =~ ^(ott-pi|pi-remote) ]]; then
    prompt_file "/persist/secrets/mqtt.env" "MQTT Telemetry Monitor Credentials (local Mosquitto)" "MQTT_HOST=127.0.0.1\nMQTT_PORT=1883\nMQTT_USER=\nMQTT_PASS=\n"
  else
    prompt_file "/persist/secrets/mqtt.env" "MQTT Telemetry Monitor Credentials" "MQTT_HOST=192.168.1.X\nMQTT_PORT=1883\nMQTT_USER=\nMQTT_PASS=\n"
  fi
  
  # SWAG Reverse Proxy (Kirkland cluster only)
  if [[ ! "$HOST" =~ ^(ott-pi|pi-remote) ]]; then
    run_wizard "/persist/secrets/swag.env" "rpi-set-swag" "SWAG Reverse Proxy Setup"
  fi
  
  # Restic Backup
  run_wizard "/persist/secrets/restic-password" "rpi-set-restic-password" "Restic Encryption Password"
  prompt_file "/persist/secrets/rclone.conf" "Rclone Configuration (Dropbox)" "[dropbox]\ntype = dropbox\ntoken = {\"access_token\":\"...\"}\n"

  echo ""
  echo "==> Phase 2: Node-Specific Secrets ($HOST)"

  case "$HOST" in
    kir-pi-primary|pi-primary)
      run_wizard "/persist/secrets/keepalived-auth.conf" "rpi-set-keepalived-auth" "Keepalived VRRP Authentication"
      run_wizard "/persist/secrets/nut-monuser-password" "rpi-set-nut-password" "NUT UPS Monitor Password"
      prompt_file "/persist/secrets/espresense-tracker.env" "ESPresense Tracker Config" "MQTT_HOST=\nMQTT_PORT=\nMQTT_USER=\nMQTT_PASS=\n"
      ;;
    kir-pi-secondary|pi-secondary)
      run_wizard "/persist/secrets/keepalived-auth.conf" "rpi-set-keepalived-auth" "Keepalived VRRP Authentication"
      if [ ! -s "/persist/secrets/wireguard/private.key" ]; then
        echo "Generating WireGuard private key..."
        mkdir -p /persist/secrets/wireguard
        ${pkgs.wireguard-tools}/bin/wg genkey > /persist/secrets/wireguard/private.key
        chmod 600 /persist/secrets/wireguard/private.key
        echo "  [✓] WireGuard private key generated."
      else
        echo "  [✓] WireGuard private key already exists."
      fi
      ;;
    ott-pi-primary|ott-pi|pi-remote)
      prompt_file "/persist/secrets/wg0.conf" "WireGuard Full Client Config" "[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...\nEndpoint = ...\nAllowedIPs = 0.0.0.0/0\n"
      prompt_file "/persist/secrets/matter-hub.env" "Matter Hub Config" "HAMH_HOME_ASSISTANT_URL=http://homeassistant.local:8123\nHAMH_HOME_ASSISTANT_ACCESS_TOKEN=\n"
      prompt_file "/persist/secrets/wyze-bridge.env" "Wyze Bridge Config" "WYZE_EMAIL=\nWYZE_PASSWORD=\nAPI_ID=\nAPI_KEY=\n"
      ;;
    *)
      echo "No specific secrets configured for unknown node: $HOST"
      ;;
  esac

  echo ""
  echo "==> Phase 3: Finalizing Setup"
  echo "Saving all changes to physical SD card..."
  rpi-persist-save
  
  echo "Restoring read-only mounts..."
  sync
  if mountpoint -q /boot/firmware; then
    mount -o remount,ro /boot/firmware 2>/dev/null || true
  fi
  mount -o remount,ro / 2>/dev/null || true
  
  echo "Restarting services with newly configured credentials..."
  systemctl reset-failed || true
  for svc in rpi-mqtt-monitor mosquitto wg-quick-wg0 wireguard-wg0 keepalived nut-server nut-monitor; do
    if systemctl list-unit-files "$svc.service" &>/dev/null; then
      systemctl restart "$svc.service" 2>/dev/null || true
    fi
  done
  if systemctl is-active docker >/dev/null 2>&1; then
    for c_svc in $(systemctl list-units --type=service --state=loaded --plain --no-legend "docker-*" 2>/dev/null | awk '{print $1}'); do
      systemctl restart "$c_svc" 2>/dev/null || true
    done
  fi

  echo ""
  echo "================================================================"
  echo "               Onboarding Complete!                             "
  echo "================================================================"
  if command -v rpi-services-status >/dev/null 2>&1; then
    echo "Current System Health:"
    rpi-services-status || true
    echo ""
  fi
  echo "Setup finished. You may reboot your Pi (sudo reboot) or continue running."
''
