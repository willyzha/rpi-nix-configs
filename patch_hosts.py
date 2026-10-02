import glob

post_exec = """
  systemd.services."restic-backups-persist".serviceConfig.ExecStopPost = [
    "-/bin/sh -c 'if [ \\"$SERVICE_RESULT\\" = \\"success\\" ]; then mkdir -p /persist/var/cache/restic && date -u +\\'%Y-%m-%dT%H:%M:%SZ\\' > /persist/var/cache/restic/last_success; fi'"
  ];
"""

for file in glob.glob('hosts/*/default.nix'):
    with open(file, 'r') as f:
        content = f.read()
    
    if 'systemd.services."restic-backups-persist".serviceConfig.ExecStopPost' not in content:
        # insert right before closing brace
        content = content.replace('\n  system.stateVersion = "24.05";\n}', post_exec + '\n  system.stateVersion = "24.05";\n}')
        
        with open(file, 'w') as f:
            f.write(content)

