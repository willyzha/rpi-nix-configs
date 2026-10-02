with open('modules/mqtt-monitor.nix', 'r') as f:
    content = f.read()

content = content.replace("raw_time=$(restic-persist snapshots --latest 1 --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].time' 2>/dev/null)", "raw_time=$(restic-persist snapshots --latest 1 --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].time' 2>/dev/null || true)")

with open('modules/mqtt-monitor.nix', 'w') as f:
    f.write(content)
