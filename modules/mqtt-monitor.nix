{ config, lib, pkgs, ... }:

let
  hostName = config.networking.hostName;
  nodeId = lib.replaceStrings [ "-" ] [ "_" ] hostName;
  displayName = if hostName == "pi-primary" then "Pi Primary" else "Pi Secondary";
  stateTopic = "rpi/${hostName}/state";
  availTopic = "rpi/${hostName}/availability";

  # Lightweight shell script that reports system telemetry to Home Assistant via MQTT Discovery
  mqttMonitorScript = pkgs.writeShellScriptBin "rpi-mqtt-monitor" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ENV_FILE="/persist/secrets/mqtt.env"
    if [ ! -f "$ENV_FILE" ]; then
      echo "MQTT config $ENV_FILE not found. Exiting." >&2
      exit 0
    fi

    # Load environment variables (MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS)
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    if [ -z "''${MQTT_HOST:-}" ]; then
      echo "MQTT_HOST not set in $ENV_FILE. Exiting." >&2
      exit 0
    fi

    PORT="''${MQTT_PORT:-1883}"
    AUTH_ARGS=()
    if [ -n "''${MQTT_USER:-}" ]; then
      AUTH_ARGS+=(-u "$MQTT_USER")
      if [ -n "''${MQTT_PASS:-}" ]; then
        AUTH_ARGS+=(-P "$MQTT_PASS")
      fi
    fi

    PUB="${pkgs.mosquitto}/bin/mosquitto_pub -h $MQTT_HOST -p $PORT ''${AUTH_ARGS[@]+''${AUTH_ARGS[@]}}"

    # 1. Publish Home Assistant MQTT Discovery configuration (retained)
    echo "==> Publishing Home Assistant MQTT Discovery configurations for ${displayName}..."

    publish_discovery() {
      local component="$1"
      local object_id="$2"
      local payload="$3"
      local topic="homeassistant/$component/${nodeId}/$object_id/config"
      $PUB -r -t "$topic" -m "$payload"
    }

    DEVICE_JSON=$(cat <<'EOF'
{
  "identifiers": ["rpi_${hostName}"],
  "name": "${displayName}",
  "model": "Raspberry Pi 3 Model B",
  "manufacturer": "Raspberry Pi Foundation",
  "sw_version": "NixOS 24.05"
}
EOF
)

    # CPU Usage Sensor
    publish_discovery "sensor" "cpu_usage" "$(cat <<EOF
{
  "name": "CPU Usage",
  "unique_id": "${nodeId}_cpu_usage",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.cpu_usage }}",
  "unit_of_measurement": "%",
  "state_class": "measurement",
  "icon": "mdi:cpu-64-bit",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # Memory Usage Sensor
    publish_discovery "sensor" "memory_usage" "$(cat <<EOF
{
  "name": "Memory Usage",
  "unique_id": "${nodeId}_memory_usage",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.memory_usage }}",
  "unit_of_measurement": "%",
  "state_class": "measurement",
  "icon": "mdi:memory",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # Memory Used Sensor (in MB)
    publish_discovery "sensor" "memory_used" "$(cat <<EOF
{
  "name": "Memory Used",
  "unique_id": "${nodeId}_memory_used",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.memory_used_mb }}",
  "unit_of_measurement": "MB",
  "device_class": "data_size",
  "state_class": "measurement",
  "icon": "mdi:memory",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # CPU Temperature Sensor
    publish_discovery "sensor" "cpu_temperature" "$(cat <<EOF
{
  "name": "CPU Temperature",
  "unique_id": "${nodeId}_cpu_temperature",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.cpu_temperature }}",
  "unit_of_measurement": "°C",
  "device_class": "temperature",
  "state_class": "measurement",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # Last Boot Timestamp Sensor
    publish_discovery "sensor" "last_boot" "$(cat <<EOF
{
  "name": "Last Boot",
  "unique_id": "${nodeId}_last_boot",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.last_boot }}",
  "device_class": "timestamp",
  "icon": "mdi:clock-outline",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # VRRP Role Status Sensor
    publish_discovery "sensor" "vrrp_status" "$(cat <<EOF
{
  "name": "VRRP Status",
  "unique_id": "${nodeId}_vrrp_status",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.vrrp_status }}",
  "icon": "mdi:server-network",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # Services Health Sensor
    publish_discovery "sensor" "services_health" "$(cat <<EOF
{
  "name": "Services Health",
  "unique_id": "${nodeId}_services_health",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.services_health }}",
  "icon": "mdi:check-network",
  "availability_topic": "${availTopic}",
  "expire_after": 90,
  "device": $DEVICE_JSON
}
EOF
)"

    # Set availability to online
    $PUB -r -t "${availTopic}" -m "online"

    # Trap to publish offline on service stop
    cleanup() {
      $PUB -r -t "${availTopic}" -m "offline" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    echo "==> Discovery configurations published. Starting telemetry loop (30s interval)..."

    get_cpu_ticks() {
      awk '/^cpu / {print $5+$6, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat
    }

    # Initial sample
    read -r prev_idle prev_total <<< "$(get_cpu_ticks)"

    while true; do
      sleep 1
      read -r curr_idle curr_total <<< "$(get_cpu_ticks)"
      idle_diff=$(( curr_idle - prev_idle ))
      total_diff=$(( curr_total - prev_total ))
      if [ "$total_diff" -gt 0 ]; then
        CPU_USAGE=$(awk -v t="$total_diff" -v i="$idle_diff" 'BEGIN { if (t > 0) printf "%.1f", ((t - i) / t) * 100; else print "0.0" }')
      else
        CPU_USAGE="0.0"
      fi
      prev_idle="$curr_idle"
      prev_total="$curr_total"

      # Memory info from /proc/meminfo
      MEM_STATS=$(awk '
        /MemTotal/ {total=$2}
        /MemAvailable/ {avail=$2}
        END {
          used = total - avail;
          pct = (used / total) * 100;
          printf "%.1f %.1f %.1f", pct, used / 1024, total / 1024;
        }
      ' /proc/meminfo)
      MEM_USAGE=$(echo "$MEM_STATS" | awk '{print $1}')
      MEM_USED_MB=$(echo "$MEM_STATS" | awk '{print $2}')
      MEM_TOTAL_MB=$(echo "$MEM_STATS" | awk '{print $3}')

      # CPU Temperature
      if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        CPU_TEMP=$(awk '{printf "%.1f", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp)
      else
        CPU_TEMP="0.0"
      fi

      # Boot timestamp (ISO 8601 UTC)
      UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
      LAST_BOOT=$(date -u -d "@$(( $(date +%s) - UPTIME_SEC ))" +'%Y-%m-%dT%H:%M:%SZ')

      # VRRP status
      if command -v rpi-vrrp-status >/dev/null 2>&1; then
        VRRP_STATUS=$(rpi-vrrp-status 2>/dev/null || echo "Unknown")
      else
        VRRP_STATUS="Unknown"
      fi

      # Services health
      if command -v rpi-services-status >/dev/null 2>&1; then
        SERVICES_HEALTH=$(rpi-services-status 2>/dev/null || echo "Unknown")
      else
        SERVICES_HEALTH="Unknown"
      fi

      # Build JSON payload using jq
      PAYLOAD=$( ${pkgs.jq}/bin/jq -n \
        --arg cpu "$CPU_USAGE" \
        --arg mem "$MEM_USAGE" \
        --arg mem_used "$MEM_USED_MB" \
        --arg mem_total "$MEM_TOTAL_MB" \
        --arg temp "$CPU_TEMP" \
        --arg uptime "$UPTIME_SEC" \
        --arg boot "$LAST_BOOT" \
        --arg vrrp "$VRRP_STATUS" \
        --arg svc "$SERVICES_HEALTH" \
        '{
          cpu_usage: ($cpu | tonumber),
          memory_usage: ($mem | tonumber),
          memory_used_mb: ($mem_used | tonumber),
          memory_total_mb: ($mem_total | tonumber),
          cpu_temperature: ($temp | tonumber),
          uptime_seconds: ($uptime | tonumber),
          last_boot: $boot,
          vrrp_status: $vrrp,
          services_health: $svc
        }'
      )

      # Publish telemetry state
      $PUB -t "${stateTopic}" -m "$PAYLOAD" || echo "Warning: Failed to publish MQTT telemetry" >&2

      # Keep availability online
      $PUB -r -t "${availTopic}" -m "online" 2>/dev/null || true

      sleep 29
    done
  '';
in
{
  environment.systemPackages = [
    pkgs.mosquitto
    mqttMonitorScript
  ];

  systemd.services.rpi-mqtt-monitor = {
    description = "Raspberry Pi MQTT Telemetry Monitor for Home Assistant";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [
      gawk
      coreutils
      gnugrep
      jq
      mosquitto
      config.system.path
    ];
    serviceConfig = {
      ExecStart = "${mqttMonitorScript}/bin/rpi-mqtt-monitor";
      Restart = "always";
      RestartSec = 10;
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };
}
