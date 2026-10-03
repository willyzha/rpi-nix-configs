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
  
  HOST=$(hostname)
  echo "Detected Node: $HOST"
  
  # Initialize secret directories and remount read-write if necessary
  rpi-init-secrets
  mount -o remount,rw /
  mount -o remount,rw /boot/firmware
  
  # Function to prompt text input and save to file
  prompt_file() {
    local file=$1
    local description=$2
    local template=$3
    
    if [ -s "$file" ]; then
      echo "  [✓] $description ($file) already exists. Skipping."
      return 0
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
    
    if [ ! -z "$template" ]; then
      echo -e "$template" > "$file"
    else
      touch "$file"
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

  # Function to run an existing wizard script if the target file doesn't exist
  run_wizard() {
    local file=$1
    local cmd=$2
    local description=$3
    
    if [ -s "$file" ]; then
      echo "  [✓] $description ($file) already exists. Skipping."
      return 0
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
  prompt_file "/persist/secrets/mqtt.env" "MQTT Telemetry Monitor Credentials" "MQTT_HOST=\nMQTT_PORT=1883\nMQTT_USER=\nMQTT_PASS=\n"
  
  # SWAG Reverse Proxy
  run_wizard "/persist/secrets/swag.env" "rpi-set-swag" "SWAG Reverse Proxy Setup"
  
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
      prompt_file "/persist/secrets/matter-hub.env" "Matter Hub Config" "HAMH_HOME_ASSISTANT_URL=\nHAMH_HOME_ASSISTANT_ACCESS_TOKEN=\n"
      prompt_file "/persist/secrets/wyze-bridge.env" "Wyze Bridge Config" "WYZE_EMAIL=\nWYZE_PASSWORD=\nAPI_ID=\nAPI_KEY=\n"
      ;;
    *)
      echo "No specific secrets configured for unknown node: $HOST"
      ;;
  esac

  echo ""
  echo "==> Phase 3: Finalizing Setup"
  echo "Saving all changes to physical SD card..."
  rpi-persist-save secrets
  
  echo "Restoring read-only mounts..."
  mount -o remount,ro /
  mount -o remount,ro /boot/firmware
  
  echo ""
  echo "================================================================"
  echo "               Onboarding Complete!                             "
  echo "================================================================"
  echo "Please reboot your Pi (sudo reboot) for all services to start cleanly."
''
