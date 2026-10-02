with open('modules/mqtt-monitor.nix', 'r') as f:
    content = f.read()

boot_logic = """
    # Restore last backup timestamp from remote on boot
    if [ ! -f /persist/var/cache/restic/last_success ]; then
      if command -v restic-persist >/dev/null 2>&1; then
        echo "==> Fetching last successful backup timestamp from remote repository..."
        raw_time=$(restic-persist snapshots --latest 1 --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].time' 2>/dev/null)
        if [ -n "$raw_time" ] && [ "$raw_time" != "null" ]; then
          mkdir -p /persist/var/cache/restic
          date -u -d "$raw_time" +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success
          echo "==> Restored last backup timestamp: $(cat /persist/var/cache/restic/last_success)"
        fi
      fi
    fi
"""

# Insert right before the initial sample in mqtt-monitor
target = '    # Initial sample\n    read -r prev_idle prev_total <<< "$(get_cpu_ticks)"'
content = content.replace(target, boot_logic + '\n' + target)

with open('modules/mqtt-monitor.nix', 'w') as f:
    f.write(content)
