{ pkgs }:

pkgs.writeShellScriptBin "rpi-wg-client" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # WireGuard Client Configuration & QR Code Generator for Raspberry Pi NixOS
  # Manages peers dynamically in runtime and persists across reboots.

  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-wg-client)" >&2
    exit 1
  fi

  WG_DIR="/persist/secrets/wireguard"
  CLIENTS_DIR="$WG_DIR/clients"
  PEERS_DIR="$WG_DIR/peers"
  mkdir -p "$CLIENTS_DIR" "$PEERS_DIR"
  chmod 700 "$WG_DIR" "$CLIENTS_DIR" "$PEERS_DIR"

  print_help() {
    cat <<EOF
WireGuard Client Manager (Raspberry Pi)

Usage:
  sudo rpi-wg-client [CLIENT_NAME] [OPTIONS]

Options:
  -q, --qr           Display only the terminal QR code
  -c, --conf         Display only the client .conf text
  -s, --show <NAME>  Show QR code and config for an existing client
  -l, --list         List all configured clients and IP allocations
  -d, --delete <NAME> Remove a client and revoke its access
  --ip <OCTET>       Manually specify host IP octet (e.g. 5 for 10.13.13.5)
  --full-tunnel      Route all client internet traffic (AllowedIPs = 0.0.0.0/0)
  -h, --help         Display this help message

Examples:
  sudo rpi-wg-client phone               # Generate client 'phone' (shows QR + config)
  sudo rpi-wg-client phone --qr          # Generate or display QR code only
  sudo rpi-wg-client --show phone        # View existing client 'phone' QR & config
  sudo rpi-wg-client --list              # List all clients
  sudo rpi-wg-client --delete phone      # Revoke and delete 'phone'
EOF
  }

  list_clients() {
    echo "================================================================"
    echo "   Configured WireGuard Clients on $(hostname)"
    echo "================================================================"
    shopt -s nullglob
    local confs=("$CLIENTS_DIR"/*.conf)
    shopt -u nullglob

    if [ ''${#confs[@]} -eq 0 ]; then
      echo "  No clients configured yet."
      echo "  Run 'sudo rpi-wg-client <name>' to create one."
      return 0
    fi

    printf "  %-18s %-16s %-16s\n" "CLIENT NAME" "IP ADDRESS" "STATUS"
    printf "  %-18s %-16s %-16s\n" "-----------" "----------" "------"

    for f in "''${confs[@]}"; do
      local name
      name=$(basename "$f" .conf)
      local ip
      ip=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$f" | cut -d= -f2 | tr -d ' ' || echo "unknown")
      local pub=""
      if [ -f "$PEERS_DIR/$name.conf" ]; then
        pub=$(grep -E '^[[:space:]]*PublicKey[[:space:]]*=' "$PEERS_DIR/$name.conf" | cut -d= -f2- | tr -d '\r\n[:space:]' || echo "")
      fi

      local active="Offline"
      if [ -n "$pub" ] && command -v ${pkgs.wireguard-tools}/bin/wg >/dev/null 2>&1; then
        if ${pkgs.wireguard-tools}/bin/wg show wg0 peers 2>/dev/null | grep -q "^$pub"; then
          active="Active"
        fi
      fi
      printf "  %-18s %-16s %-16s\n" "$name" "$ip" "$active"
    done
    echo ""
  }

  delete_client() {
    local name="$1"
    local peer_conf="$PEERS_DIR/$name.conf"
    local client_conf="$CLIENTS_DIR/$name.conf"

    if [ ! -f "$client_conf" ] && [ ! -f "$peer_conf" ]; then
      echo "Error: Client '$name' not found." >&2
      exit 1
    fi

    if [ -f "$peer_conf" ]; then
      local pub
      pub=$(grep -E '^[[:space:]]*PublicKey[[:space:]]*=' "$peer_conf" | cut -d= -f2- | tr -d '\r\n[:space:]' || echo "")
      if [ -n "$pub" ] && command -v ${pkgs.wireguard-tools}/bin/wg >/dev/null 2>&1; then
        ${pkgs.wireguard-tools}/bin/wg set wg0 peer "$pub" remove 2>/dev/null || true
      fi
      rm -f "$peer_conf"
    fi

    rm -f "$client_conf" "$CLIENTS_DIR/$name.png"
    echo "==> Client '$name' removed successfully."

    if command -v rpi-persist-save >/dev/null 2>&1; then
      rpi-persist-save wireguard >/dev/null 2>&1 || true
    fi
  }

  render_qr() {
    local conf_file="$1"
    # Minify on the fly: strip comments, blank lines, and unnecessary spaces
    # Use 1-module margin (-m 1) for the most compact terminal representation
    grep -v '^[[:space:]]*#' "$conf_file" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*=[[:space:]]*/=/g' | sed 's/,[[:space:]]*/,/g' | ${pkgs.qrencode}/bin/qrencode -t ansiutf8 -m 1
  }

  show_client() {
    local name="$1"
    local mode="''${2:-both}"
    local client_conf="$CLIENTS_DIR/$name.conf"
    local client_png="$CLIENTS_DIR/$name.png"

    if [ ! -f "$client_conf" ]; then
      echo "Error: Client config '$client_conf' not found." >&2
      echo "Use 'rpi-wg-client --list' to see existing clients." >&2
      exit 1
    fi

    # Ensure companion PNG file exists
    if [ ! -f "$client_png" ] && command -v ${pkgs.qrencode}/bin/qrencode >/dev/null 2>&1; then
      ${pkgs.qrencode}/bin/qrencode -s 6 -m 2 -o "$client_png" < "$client_conf" 2>/dev/null || true
      chmod 600 "$client_png" 2>/dev/null || true
    fi

    if [ "$mode" = "qr" ] || [ "$mode" = "both" ]; then
      echo ""
      echo "==> Scan this QR Code with the WireGuard App on your device:"
      echo ""
      render_qr "$client_conf"
      echo ""
    fi

    if [ "$mode" = "conf" ] || [ "$mode" = "both" ]; then
      echo "==> Client Configuration File: $client_conf"
      echo "----------------------------------------------------------------"
      cat "$client_conf"
      echo "----------------------------------------------------------------"
    fi
  }

  # Parse CLI arguments
  CLIENT_NAME=""
  OUTPUT_MODE="both"
  CUSTOM_IP=""
  FULL_TUNNEL=false

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        print_help
        exit 0
        ;;
      -l|--list)
        list_clients
        exit 0
        ;;
      -d|--delete|--remove)
        shift
        if [ $# -eq 0 ]; then
          echo "Error: --delete requires a client name." >&2
          exit 1
        fi
        delete_client "$1"
        exit 0
        ;;
      -s|--show)
        shift
        if [ $# -eq 0 ]; then
          echo "Error: --show requires a client name." >&2
          exit 1
        fi
        CLIENT_NAME="$1"
        shift
        if [ ''${1:-} = "--qr" ] || [ ''${1:-} = "-q" ]; then
          OUTPUT_MODE="qr"
        elif [ ''${1:-} = "--conf" ] || [ ''${1:-} = "-c" ]; then
          OUTPUT_MODE="conf"
        fi
        show_client "$CLIENT_NAME" "$OUTPUT_MODE"
        exit 0
        ;;
      -q|--qr)
        OUTPUT_MODE="qr"
        shift
        ;;
      -c|--conf)
        OUTPUT_MODE="conf"
        shift
        ;;
      --ip)
        shift
        CUSTOM_IP="$1"
        shift
        ;;
      --full-tunnel)
        FULL_TUNNEL=true
        shift
        ;;
      -*)
        echo "Error: Unknown option '$1'." >&2
        print_help
        exit 1
        ;;
      *)
        if [ -z "$CLIENT_NAME" ]; then
          CLIENT_NAME="$1"
        fi
        shift
        ;;
    esac
  done

  # If client name was not given, prompt interactively
  if [ -z "$CLIENT_NAME" ]; then
    read -rp "Enter new client name (e.g. phone, laptop, ipad): " CLIENT_NAME
  fi

  # Sanitize name
  CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
  if [ -z "$CLIENT_NAME" ]; then
    echo "Error: Invalid client name. Use alphanumeric characters, hyphens, and underscores." >&2
    exit 1
  fi

  # If client already exists, ask or display
  CLIENT_CONF="$CLIENTS_DIR/$CLIENT_NAME.conf"
  PEER_CONF="$PEERS_DIR/$CLIENT_NAME.conf"
  if [ -f "$CLIENT_CONF" ]; then
    echo "Notice: Client '$CLIENT_NAME' already exists."
    show_client "$CLIENT_NAME" "$OUTPUT_MODE"
    exit 0
  fi

  # Auto-detect Server Public Key
  SERVER_PUB=""
  if [ -f "$WG_DIR/public.key" ]; then
    SERVER_PUB=$(tr -d '\r\n[:space:]' < "$WG_DIR/public.key")
  elif command -v ${pkgs.wireguard-tools}/bin/wg >/dev/null 2>&1; then
    SERVER_PUB=$(${pkgs.wireguard-tools}/bin/wg show wg0 public-key 2>/dev/null || true)
  fi

  if [ -z "$SERVER_PUB" ]; then
    echo "Error: WireGuard server public key not found in $WG_DIR/public.key" >&2
    exit 1
  fi

  # Auto-detect Server Endpoint (Dynamic DNS / Public Domain)
  SERVER_ENDPOINT=""
  if [ -f "/persist/secrets/swag.env" ]; then
    SERVER_ENDPOINT=$(grep -E '^[[:space:]]*URL=' /persist/secrets/swag.env | cut -d= -f2- | tr -d '\r\n[:space:]' || true)
  fi
  if [ -z "$SERVER_ENDPOINT" ] && [ -f "/persist/secrets/cloudflare.env" ]; then
    SERVER_ENDPOINT=$(grep -E '^[[:space:]]*CLOUDFLARE_DOMAINS=' /persist/secrets/cloudflare.env | head -n 1 | awk '{gsub(/["\047]/, ""); print $1}' || true)
  fi
  if [ -z "$SERVER_ENDPOINT" ]; then
    SERVER_ENDPOINT="wzhang.dev"
  fi

  SERVER_PORT="51820"
  if command -v ${pkgs.wireguard-tools}/bin/wg >/dev/null 2>&1; then
    ACTIVE_PORT=$(${pkgs.wireguard-tools}/bin/wg show wg0 listen-port 2>/dev/null || true)
    [ -n "$ACTIVE_PORT" ] && SERVER_PORT="$ACTIVE_PORT"
  fi

  # Determine Client IP Octet
  ASSIGNED_OCTET=""
  if [ -n "$CUSTOM_IP" ]; then
    ASSIGNED_OCTET="$CUSTOM_IP"
  else
    # Scan existing client and peer configs for used octets
    USED_OCTETS=(1) # 1 is reserved for server 10.13.13.1
    for f in "$PEERS_DIR"/*.conf "$CLIENTS_DIR"/*.conf; do
      if [ -f "$f" ]; then
        oct=$(grep -oE '10\.13\.13\.[0-9]+' "$f" 2>/dev/null | cut -d. -f4 | sort -u || true)
        for o in $oct; do
          USED_OCTETS+=("$o")
        done
      fi
    done

    # Find first available octet between 2 and 254
    for (( i=2; i<=254; i++ )); do
      if [[ ! " ''${USED_OCTETS[*]} " =~ [[:space:]]''${i}[[:space:]] ]]; then
        ASSIGNED_OCTET="$i"
        break
      fi
    done
  fi

  if [ -z "$ASSIGNED_OCTET" ]; then
    echo "Error: No available IP addresses in 10.13.13.0/24 subnet." >&2
    exit 1
  fi

  CLIENT_IP="10.13.13.''${ASSIGNED_OCTET}"

  # Tunnel routing
  if [ "$FULL_TUNNEL" = "true" ]; then
    ALLOWED_IPS="0.0.0.0/0, ::/0"
  else
    ALLOWED_IPS="10.13.13.0/24, 192.168.1.0/24"
  fi

  echo "==> Creating WireGuard profile for: $CLIENT_NAME"
  echo "    Assigned IP : $CLIENT_IP/32"
  echo "    Endpoint    : $SERVER_ENDPOINT:$SERVER_PORT"
  echo "    Allowed IPs : $ALLOWED_IPS"

  # Generate Client Keypair
  CLIENT_PRIV=$(${pkgs.wireguard-tools}/bin/wg genkey)
  CLIENT_PUB=$(echo "$CLIENT_PRIV" | ${pkgs.wireguard-tools}/bin/wg pubkey)

  # 1. Write Client Configuration File
  cat <<EOF > "$CLIENT_CONF"
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_IP/32
DNS = 10.13.13.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_CONF"

  # Generate companion PNG image
  CLIENT_PNG="$CLIENTS_DIR/$CLIENT_NAME.png"
  if command -v ${pkgs.qrencode}/bin/qrencode >/dev/null 2>&1; then
    ${pkgs.qrencode}/bin/qrencode -s 6 -m 2 -o "$CLIENT_PNG" < "$CLIENT_CONF" 2>/dev/null || true
    chmod 600 "$CLIENT_PNG" 2>/dev/null || true
  fi

  # 2. Write Server Peer Configuration File
  cat <<EOF > "$PEER_CONF"
[Peer]
# Client: $CLIENT_NAME
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP/32
EOF
  chmod 600 "$PEER_CONF"

  # 3. Add to Live WireGuard Interface (Instant Connectivity)
  if command -v ${pkgs.wireguard-tools}/bin/wg >/dev/null 2>&1; then
    ${pkgs.wireguard-tools}/bin/wg set wg0 peer "$CLIENT_PUB" allowed-ips "$CLIENT_IP/32"
    echo "    [✓] Peer registered in running WireGuard interface (wg0)"
  fi

  # 4. Save to physical SD card via rpi-persist-save
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save wireguard >/dev/null 2>&1 || true
    echo "    [✓] Profile committed to physical SD card (/persist-raw)"
  fi

  # 5. Display QR Code / Configuration
  show_client "$CLIENT_NAME" "$OUTPUT_MODE"

  echo ""
  echo "==> Setup Complete!"
  echo "  - To redisplay this QR code: sudo rpi-wg-client --show $CLIENT_NAME"
  echo "  - To download configuration / QR image to your computer:"
  echo "      scp root@$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname):$CLIENT_CONF ./"
  echo "      scp root@$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname):$CLIENT_PNG ./"
  echo "  - Tip: If the QR code is still large for your terminal window, zoom out with Ctrl - / Cmd -"
  echo ""
''
