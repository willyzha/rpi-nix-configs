import re

with open('modules/mqtt-monitor.nix', 'r') as f:
    content = f.read()

# The first match is inside listen_ha_birth
target = """    listen_ha_birth() {
      while true; do
      # Restore last backup timestamp from remote once NTP is synced
      if [ ! -f /persist/var/cache/restic/last_success ] && [ "$FETCHED_BACKUP" -eq 0 ]; then
        if [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]; then
          if command -v restic-persist >/dev/null 2>&1; then
            echo "==> Fetching last successful backup timestamp from remote repository..."
            raw_time=$(restic-persist snapshots --latest 1 --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].time' 2>/dev/null || true)
            if [ -n "$raw_time" ] && [ "$raw_time" != "null" ]; then
              mkdir -p /persist/var/cache/restic
              date -u -d "$raw_time" +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success
              echo "==> Restored last backup timestamp: $(cat /persist/var/cache/restic/last_success)"
            fi
          fi
          FETCHED_BACKUP=1
        fi
      fi
"""
content = content.replace(target, """    listen_ha_birth() {
      while true; do
""")

with open('modules/mqtt-monitor.nix', 'w') as f:
    f.write(content)
