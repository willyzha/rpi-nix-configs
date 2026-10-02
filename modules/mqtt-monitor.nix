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

    publish_all_discovery() {
      echo "==> Publishing Home Assistant MQTT Discovery configurations for ${displayName}..."

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
  "expire_after": 60,
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
  "expire_after": 60,
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
  "expire_after": 60,
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
  "expire_after": 60,
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
  "expire_after": 60,
  "device": $DEVICE_JSON
}
EOF
)"


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
  "expire_after": 60,
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
  "expire_after": 60,
  "json_attributes_topic": "${stateTopic}",
  "json_attributes_template": "{{ {'virtual_ip': value_json.vrrp_vip} | tojson }}",
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
  "expire_after": 60,
  "device": $DEVICE_JSON
}
EOF
)"

      # Home Assistant Update Entity
      publish_discovery "update" "update" "$(cat <<EOF
{
  "name": "Update",
  "unique_id": "${nodeId}_update",
  "state_topic": "${stateTopic}",
  "value_template": "{{ value_json.installed_version }}",
  "latest_version_topic": "${stateTopic}",
  "latest_version_template": "{{ value_json.latest_version }}",
  "title": "NixOS Flake Update",
  "release_url": "https://github.com/willyzha/rpi-nix-configs/commits/main",
  "entity_picture": "https://raw.githubusercontent.com/NixOS/nixos-artwork/master/logo/nix-snowflake.svg",
  "availability_topic": "${availTopic}",
  "expire_after": 60,
  "device": $DEVICE_JSON
}
EOF
)"

      # Update Available Binary Sensor
      publish_discovery "binary_sensor" "update_available" "$(cat <<EOF
{
  "name": "Update Available",
  "unique_id": "${nodeId}_update_available",
  "state_topic": "${stateTopic}",
  "value_template": "{{ 'ON' if value_json.update_available else 'OFF' }}",
  "payload_on": "ON",
  "payload_off": "OFF",
  "device_class": "update",
  "availability_topic": "${availTopic}",
  "expire_after": 60,
  "json_attributes_topic": "${stateTopic}",
  "json_attributes_template": "{{ {'installed_version': value_json.installed_version, 'latest_version': value_json.latest_version, 'last_checked': value_json.update_last_checked} | tojson }}",
  "device": $DEVICE_JSON
}
EOF
)"

      # Set availability to online
      $PUB -r -t "${availTopic}" -m "online" 2>/dev/null || true
    }

    # Initial publication
    publish_all_discovery

    # Background listener for Home Assistant birth message (homeassistant/status == online)
    HA_TRIGGER="/run/rpi-mqtt-discovery-trigger"
    rm -f "$HA_TRIGGER"

    listen_ha_birth() {
      while true; do
        ${pkgs.mosquitto}/bin/mosquitto_sub -h "$MQTT_HOST" -p "$PORT" ''${AUTH_ARGS[@]+''${AUTH_ARGS[@]}} -t "homeassistant/status" -q 0 2>/dev/null | while read -r status; do
          if [ "$status" = "online" ]; then
            touch "$HA_TRIGGER"
          fi
        done || true
        sleep 10
      done
    }

    listen_ha_birth &
    SUB_PID=$!

    # Trap to publish offline on service stop
    cleanup() {
      kill -TERM "$SUB_PID" 2>/dev/null || true
      pkill -P "$SUB_PID" 2>/dev/null || true
      $PUB -r -t "${availTopic}" -m "offline" 2>/dev/null || true
      rm -f "$HA_TRIGGER"
    }
    trap cleanup EXIT INT TERM

    echo "==> Discovery configurations published. Starting telemetry loop (30s interval)..."

    get_cpu_ticks() {
      awk '/^cpu / {print $5+$6, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat
    }

    UPDATE_CACHE="/run/rpi-check-update.cache"
    UPDATE_INTERVAL=43200 # 12 hours in seconds

    get_update_status() {
      local now
      now=$(date +%s)
      local cache_time=0
      local need_check=0

      if [ -f "$UPDATE_CACHE" ]; then
        cache_time=$(head -n 1 "$UPDATE_CACHE" 2>/dev/null || echo 0)
        if ! [[ "$cache_time" =~ ^[0-9]+$ ]]; then
          cache_time=0
        fi
      fi

      if [ "$cache_time" -eq 0 ] || [ $(( now - cache_time )) -ge "$UPDATE_INTERVAL" ]; then
        need_check=1
      fi

      if [ "$need_check" -eq 1 ]; then
        if command -v rpi-check-update >/dev/null 2>&1; then
          rpi-check-update --json >/dev/null 2>&1 || true
        fi
      fi

      if [ -f "$UPDATE_CACHE" ]; then
        local cached_json
        cached_json=$(tail -n +2 "$UPDATE_CACHE" 2>/dev/null || true)
        if [ -n "$cached_json" ]; then
          echo "$cached_json"
          return 0
        fi
      fi

      local cur_rev="unknown"
      if [ -f /run/current-system/configuration-revision ]; then
        cur_rev=$(cat /run/current-system/configuration-revision | tr -d '\r\n[:space:]')
      fi
      local cur_short="''${cur_rev:0:12}"
      [ -z "$cur_short" ] && cur_short="unknown"

      ${pkgs.jq}/bin/jq -n \
        --arg inst "$cur_short" \
        '{
          update_available: false,
          installed_version: $inst,
          latest_version: $inst,
          installed_revision: $inst,
          latest_revision: $inst,
          last_checked: "never"
        }'
    }


    # Restore last backup timestamp from remote on boot
    if [ ! -f /persist/var/cache/restic/last_success ]; then
      if command -v restic-persist >/dev/null 2>&1; then
        echo "==> Fetching last successful backup timestamp from remote repository..."
        raw_time=$(restic-persist snapshots --latest 1 --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].time' 2>/dev/null || true)
        if [ -n "$raw_time" ] && [ "$raw_time" != "null" ]; then
          mkdir -p /persist/var/cache/restic
          date -u -d "$raw_time" +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success
          echo "==> Restored last backup timestamp: $(cat /persist/var/cache/restic/last_success)"
        fi
      fi
    fi

    # Initial sample
    read -r prev_idle prev_total <<< "$(get_cpu_ticks)"

    LOOP_COUNT=0
    BROKER_FAILED=0

    while true; do
      # Check if Home Assistant sent a birth message
      if [ -f "$HA_TRIGGER" ]; then
        rm -f "$HA_TRIGGER"
        echo "==> Home Assistant birth detected (homeassistant/status online). Re-publishing discovery..."
        publish_all_discovery
      fi

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
      if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        LAST_BOOT=$(date -u -d "@$(( $(date +%s) - UPTIME_SEC ))" +'%Y-%m-%dT%H:%M:%SZ')
      else
        LAST_BOOT="null"
      fi


      # Restic Backup status
      if [ -f /persist/var/cache/restic/last_success ]; then
        LAST_BACKUP=$(cat /persist/var/cache/restic/last_success)
      else
        LAST_BACKUP="null"
      fi

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

      # Update status from local cache (/run/rpi-check-update.cache, refreshed max once every 12h)
      UPDATE_INFO=$(get_update_status)
      UPDATE_AVAIL=$(echo "$UPDATE_INFO" | ${pkgs.jq}/bin/jq -r '.update_available // false')
      INSTALLED_VER=$(echo "$UPDATE_INFO" | ${pkgs.jq}/bin/jq -r '.installed_version // "unknown"')
      LATEST_VER=$(echo "$UPDATE_INFO" | ${pkgs.jq}/bin/jq -r '.latest_version // "unknown"')
      UPDATE_CHECKED=$(echo "$UPDATE_INFO" | ${pkgs.jq}/bin/jq -r '.last_checked // "unknown"')

      # Build JSON payload using jq
      PAYLOAD=$( ${pkgs.jq}/bin/jq -n \
        --arg cpu "$CPU_USAGE" \
        --arg mem "$MEM_USAGE" \
        --arg mem_used "$MEM_USED_MB" \
        --arg mem_total "$MEM_TOTAL_MB" \
        --arg temp "$CPU_TEMP" \
        --arg uptime "$UPTIME_SEC" \
        --arg boot "$LAST_BOOT" \
        --arg backup "$LAST_BACKUP" \
        --arg vrrp "$VRRP_STATUS" \
        --arg svc "$SERVICES_HEALTH" \
        --argjson update "$UPDATE_AVAIL" \
        --arg inst "$INSTALLED_VER" \
        --arg late "$LATEST_VER" \
        --arg checked "$UPDATE_CHECKED" \
        '{
          cpu_usage: ($cpu | tonumber),
          memory_usage: ($mem | tonumber),
          memory_used_mb: ($mem_used | tonumber),
          memory_total_mb: ($mem_total | tonumber),
          cpu_temperature: ($temp | tonumber),
          uptime_seconds: ($uptime | tonumber),
          last_boot: (if $boot == "null" then null else $boot end),
          last_backup: (if $backup == "null" then null else $backup end),
          vrrp_status: $vrrp,
          vrrp_vip: "192.168.1.9",
          services_health: $svc,
          update_available: $update,
          installed_version: $inst,
          latest_version: $late,
          update_last_checked: $checked
        }'
      )

      # Publish telemetry state (retained)
      if $PUB -r -t "${stateTopic}" -m "$PAYLOAD"; then
        if [ "$BROKER_FAILED" -eq 1 ]; then
          echo "==> MQTT broker reconnected. Re-publishing discovery configurations..."
          publish_all_discovery
          BROKER_FAILED=0
        fi
        # Keep availability online
        $PUB -r -t "${availTopic}" -m "online" 2>/dev/null || true
      else
        echo "Warning: Failed to publish MQTT telemetry (broker unreachable)" >&2
        BROKER_FAILED=1
      fi

      LOOP_COUNT=$(( LOOP_COUNT + 1 ))
      # Safety: Re-publish discovery configs every 10 minutes (20 loops * 30s)
      if [ $(( LOOP_COUNT % 20 )) -eq 0 ]; then
        publish_all_discovery
      fi

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
