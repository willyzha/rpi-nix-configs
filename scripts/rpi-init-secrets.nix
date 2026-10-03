{ pkgs }:

pkgs.writeShellScriptBin "rpi-init-secrets" ''
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

  CURRENT_HOST="''${HOST:-$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)}"

  # MQTT broker configuration for Home Assistant telemetry
  if [ ! -f /persist/secrets/mqtt.env ]; then
    DEFAULT_MQTT_HOST="192.168.1.X"
    if [[ "$CURRENT_HOST" =~ ^(ott-pi-primary|ott-pi|pi-remote) ]]; then
      DEFAULT_MQTT_HOST="127.0.0.1"
    fi
    cat <<EOF > /persist/secrets/mqtt.env
MQTT_HOST=$DEFAULT_MQTT_HOST
MQTT_PORT=1883
MQTT_USER=
MQTT_PASS=
EOF
    chmod 600 /persist/secrets/mqtt.env
    echo "  [CREATED] /persist/secrets/mqtt.env (default: $DEFAULT_MQTT_HOST:1883)"
  else
    echo "  [OK]      /persist/secrets/mqtt.env"
  fi
  if [[ "$CURRENT_HOST" =~ ^(kir-pi-primary|pi-primary) ]]; then
    if [ ! -f /persist/secrets/espresense-tracker.env ]; then
      cat <<'EOF' > /persist/secrets/espresense-tracker.env
MQTT_HOST=192.168.1.10
MQTT_PORT=1883
MQTT_USER=
MQTT_PASSWORD=
DEVICES=
EOF
      chmod 600 /persist/secrets/espresense-tracker.env
      echo "  [CREATED] /persist/secrets/espresense-tracker.env (default stub)"
    else
      echo "  [OK]      /persist/secrets/espresense-tracker.env"
    fi
  fi

  if [[ "$CURRENT_HOST" =~ ^(ott-pi-primary|ott-pi|pi-remote) ]]; then
    if [ ! -f /persist/secrets/matter-hub.env ]; then
      cat <<'EOF' > /persist/secrets/matter-hub.env
HAMH_HOME_ASSISTANT_URL=http://homeassistant.local:8123
HAMH_HOME_ASSISTANT_ACCESS_TOKEN=
EOF
      chmod 600 /persist/secrets/matter-hub.env
      echo "  [CREATED] /persist/secrets/matter-hub.env (default stub)"
    else
      echo "  [OK]      /persist/secrets/matter-hub.env"
    fi

    if [ ! -f /persist/secrets/wyze-bridge.env ]; then
      cat <<'EOF' > /persist/secrets/wyze-bridge.env
WYZE_EMAIL=
WYZE_PASSWORD=
API_ID=
API_KEY=
EOF
      chmod 600 /persist/secrets/wyze-bridge.env
      echo "  [CREATED] /persist/secrets/wyze-bridge.env (default stub)"
    else
      echo "  [OK]      /persist/secrets/wyze-bridge.env"
    fi

    if [ ! -f /persist/secrets/wg0.conf ]; then
      DUMMY_KEY=$(${pkgs.wireguard-tools}/bin/wg genkey)
      DUMMY_PUB=$(${pkgs.wireguard-tools}/bin/wg pubkey <<< "$DUMMY_KEY")
      cat <<EOF > /persist/secrets/wg0.conf
[Interface]
PrivateKey = $DUMMY_KEY
Address = 10.13.13.2/24

[Peer]
PublicKey = $DUMMY_PUB
Endpoint = 127.0.0.1:51820
AllowedIPs = 10.13.13.1/32
EOF
      chmod 600 /persist/secrets/wg0.conf
      echo "  [CREATED] /persist/secrets/wg0.conf (starter stub)"
    else
      echo "  [OK]      /persist/secrets/wg0.conf"
    fi
  fi

  echo "==> All secret files verified."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save secrets
  fi
''
