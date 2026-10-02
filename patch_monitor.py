import re
with open('modules/mqtt-monitor.nix', 'r') as f:
    content = f.read()

# Add discovery for last_backup
discovery_block = """
      # Last Backup Timestamp Sensor
      publish_discovery "sensor" "last_backup" "$(cat <<EOF
{
  "name": "Last Backup",
  "unique_id": "${nodeId}_last_backup",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.last_backup }}",
  "device_class": "timestamp",
  "entity_category": "diagnostic",
  "icon": "mdi:cloud-check",
  "availability_topic": "${availTopic}",
  "expire_after": 180,
  "device": $DEVICE_JSON
}
EOF
)"
"""

content = re.sub(r'(      # Last Boot Timestamp Sensor\n      publish_discovery "sensor" "last_boot" "\$\(cat <<EOF\n\{.*?\nEOF\n\)"\n)', r'\1\n' + discovery_block, content, flags=re.DOTALL)

# Add logic to read last_backup
payload_logic = """
      # Restic Backup status
      if [ -f /persist/var/cache/restic/last_success ]; then
        LAST_BACKUP=$(cat /persist/var/cache/restic/last_success)
      else
        LAST_BACKUP="null"
      fi
"""

content = content.replace('      # VRRP status\n      if command -v rpi-vrrp-status >/dev/null 2>&1; then', payload_logic + '\n      # VRRP status\n      if command -v rpi-vrrp-status >/dev/null 2>&1; then')

# Add to jq payload
jq_args = '        --arg boot "$LAST_BOOT" \\\n        --arg backup "$LAST_BACKUP" \\'
content = content.replace('        --arg boot "$LAST_BOOT" \\', jq_args)

jq_json = '          last_boot: (if $boot == "null" then null else $boot end),\n          last_backup: (if $backup == "null" then null else $backup end),'
content = content.replace('          last_boot: (if $boot == "null" then null else $boot end),', jq_json)

with open('modules/mqtt-monitor.nix', 'w') as f:
    f.write(content)

