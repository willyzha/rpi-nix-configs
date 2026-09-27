{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-keepalived-auth" ''
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
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save secrets/keepalived-auth.conf
  fi
  if systemctl list-unit-files | grep -q keepalived.service; then
    echo "==> Restarting keepalived.service..."
    systemctl restart keepalived.service || true
  fi
''
