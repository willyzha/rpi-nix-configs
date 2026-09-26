{ config, lib, pkgs, ... }:

{
  # Time zone matching your existing setup
  time.timeZone = "America/Los_Angeles";

  # Localization
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable zram compressed swap to prevent OOM on 1GB RAM Pi 3
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Nix configuration
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = false; # Avoid heavy disk writes on SD
      warn-dirty = false;
    };
    gc = {
      automatic = false; # Manual GC preferred to avoid unexpected SD writes
    };
  };

  # Networking
  networking = {
    usePredictableInterfaceNames = lib.mkDefault false; # Keep eth0 interface name for SMSC9514 USB-Ethernet
    useDHCP = lib.mkDefault true; # Auto-detect IP, router gateway, and DNS on any network
    firewall.enable = false; # Disable internal firewall by default (handled by container/services)
  };

  # Zero-config local network discovery (e.g., ssh pi@pi-primary.local)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true;
    };
  };

  # Allow user passwords to be modified via passwd (survives reboots on ext4 root)
  users.mutableUsers = true;

  # Default user 'pi'
  users.users.pi = {
    isNormalUser = true;
    home = "/home/pi";
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFz7zweHTuKuHEQv7xtzH8I3T1Ch+Mafg+S4a00hcniR willyzha@willy-dev"
    ];
  };

  # Passwordless sudo for wheel group
  security.sudo = {
    wheelNeedsPassword = false;
  };

  # Common utility packages
  environment.systemPackages = with pkgs; [
    vim
    nano
    git
    curl
    wget
    htop
    iotop
    tmux
    rsync
    ncdu
    pciutils
    usbutils
    jq
    restic
    rclone
    wireguard-tools
    psmisc
    lsof

    # Helper script: safely set 'pi' login password on read-only root
    (pkgs.writeShellScriptBin "rpi-set-password" ''
      #!/usr/bin/env bash
      set -euo pipefail
      if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run as root (e.g. sudo rpi-set-password)" >&2
        exit 1
      fi
      TARGET_USER="''${1:-pi}"
      echo "==> Remounting / as Read-Write..."
      mount -o remount,rw /
      cleanup() {
        echo "==> Restoring / as Read-Only..."
        mount -o remount,ro / || true
      }
      trap cleanup EXIT
      echo "==> Setting password for user '$TARGET_USER'..."
      passwd "$TARGET_USER"
      echo "==> Password successfully updated and saved to disk."
    '')

    # Helper script: set NUT UPS monitor password
    (pkgs.writeShellScriptBin "rpi-set-nut-password" ''
      #!/usr/bin/env bash
      set -euo pipefail
      if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run as root (e.g. sudo rpi-set-nut-password)" >&2
        exit 1
      fi
      PASSWORD="''${1:-}"
      if [ -z "$PASSWORD" ]; then
        read -rsp "Enter new NUT monitor password: " PASSWORD
        echo
      fi
      mkdir -p /persist/secrets
      echo -n "$PASSWORD" > /persist/secrets/nut-monuser-password
      chmod 600 /persist/secrets/nut-monuser-password
      echo "==> /persist/secrets/nut-monuser-password updated."
      if systemctl list-unit-files | grep -q upsd.service; then
        echo "==> Restarting upsd.service..."
        systemctl restart upsd.service || true
      fi
    '')

    # Helper script: set Keepalived cluster auth password
    (pkgs.writeShellScriptBin "rpi-set-keepalived-auth" ''
      #!/usr/bin/env bash
      set -euo pipefail
      if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run as root (e.g. sudo rpi-set-keepalived-auth)" >&2
        exit 1
      fi
      PASSWORD="''${1:-}"
      if [ -z "$PASSWORD" ]; then
        read -rsp "Enter Keepalived cluster auth password: " PASSWORD
        echo
      fi
      mkdir -p /persist/secrets
      cat <<EOF > /persist/secrets/keepalived-auth.conf
authentication {
  auth_type PASS
  auth_pass $PASSWORD
}
EOF
      chmod 600 /persist/secrets/keepalived-auth.conf
      echo "==> /persist/secrets/keepalived-auth.conf updated."
      if systemctl list-unit-files | grep -q keepalived.service; then
        echo "==> Restarting keepalived.service..."
        systemctl restart keepalived.service || true
      fi
    '')

    # Helper script: set Restic backup repository password
    (pkgs.writeShellScriptBin "rpi-set-restic-password" ''
      #!/usr/bin/env bash
      set -euo pipefail
      if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run as root (e.g. sudo rpi-set-restic-password)" >&2
        exit 1
      fi
      PASSWORD="''${1:-}"
      if [ -z "$PASSWORD" ]; then
        read -rsp "Enter new Restic backup password: " PASSWORD
        echo
      fi
      mkdir -p /persist/secrets
      echo -n "$PASSWORD" > /persist/secrets/restic-password
      chmod 600 /persist/secrets/restic-password
      echo "==> /persist/secrets/restic-password updated."
    '')

    # Helper script: verify and initialize all persistent secret stubs
    (pkgs.writeShellScriptBin "rpi-init-secrets" ''
      #!/usr/bin/env bash
      set -euo pipefail
      if [ "$EUID" -ne 0 ]; then
        echo "Error: Please run as root (e.g. sudo rpi-init-secrets)" >&2
        exit 1
      fi
      mkdir -p /persist/secrets /persist/secrets/wireguard
      chmod 700 /persist/secrets /persist/secrets/wireguard

      echo "==> Checking persistent secret files..."

      # NUT password
      if [ ! -f /persist/secrets/nut-monuser-password ]; then
        echo "changeme" > /persist/secrets/nut-monuser-password
        chmod 600 /persist/secrets/nut-monuser-password
        echo "  [CREATED] /persist/secrets/nut-monuser-password (default: changeme)"
      else
        echo "  [OK]      /persist/secrets/nut-monuser-password"
      fi

      # Keepalived auth
      if [ ! -f /persist/secrets/keepalived-auth.conf ]; then
        cat <<'EOF' > /persist/secrets/keepalived-auth.conf
authentication {
  auth_type PASS
  auth_pass changeme
}
EOF
        chmod 600 /persist/secrets/keepalived-auth.conf
        echo "  [CREATED] /persist/secrets/keepalived-auth.conf (default: changeme)"
      else
        echo "  [OK]      /persist/secrets/keepalived-auth.conf"
      fi

      # WireGuard server key
      if [ ! -f /persist/secrets/wireguard/private.key ]; then
        ${pkgs.wireguard-tools}/bin/wg genkey > /persist/secrets/wireguard/private.key
        chmod 600 /persist/secrets/wireguard/private.key
        ${pkgs.wireguard-tools}/bin/wg pubkey < /persist/secrets/wireguard/private.key > /persist/secrets/wireguard/public.key
        echo "  [CREATED] /persist/secrets/wireguard/private.key (new WireGuard keypair)"
      else
        echo "  [OK]      /persist/secrets/wireguard/private.key"
      fi

      # Restic backup password
      if [ ! -f /persist/secrets/restic-password ]; then
        echo "changeme" > /persist/secrets/restic-password
        chmod 600 /persist/secrets/restic-password
        echo "  [CREATED] /persist/secrets/restic-password (default: changeme)"
      else
        echo "  [OK]      /persist/secrets/restic-password"
      fi

      # SWAG domain and email
      if [ ! -f /persist/secrets/swag.env ]; then
        cat <<'EOF' > /persist/secrets/swag.env
URL=example.com
EMAIL=admin@example.com
EOF
        chmod 600 /persist/secrets/swag.env
        echo "  [CREATED] /persist/secrets/swag.env (default: example.com)"
      else
        echo "  [OK]      /persist/secrets/swag.env"
      fi

      echo "==> All secret files verified."
    '')

    # Helper script: interactively configure all private SWAG fields (URL, EMAIL, Cloudflare token)
    (pkgs.writeShellScriptBin "rpi-set-swag" ''
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

      echo
      echo "==> SWAG private credentials successfully saved."
      if systemctl list-unit-files | grep -q docker-swag.service; then
        echo "==> Restarting docker-swag..."
        systemctl restart docker-swag.service || true
        echo "==> SWAG restarted. Run 'docker logs -f swag' to monitor certificate generation."
      fi
    '')
  ];

  # Allow unfree packages if needed
  nixpkgs.config.allowUnfree = true;
}
