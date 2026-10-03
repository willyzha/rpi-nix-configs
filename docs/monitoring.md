# Cluster Monitoring & Home Assistant Integration

Both nodes run a lightweight native telemetry service (**`rpi-mqtt-monitor`**) that reports health and system performance metrics to your MQTT broker every 30 seconds using **Home Assistant MQTT Auto-Discovery**.

> [!TIP]
> **Zero YAML Required in Home Assistant**: Both nodes automatically register themselves as clean devices (**`Pi Primary`** and **`Pi Secondary`**) with all sensors grouped neatly under each device card.

### Monitored Sensors

| Sensor | Entity ID | Device Class / Unit | Description |
| :--- | :--- | :--- | :--- |
| **CPU Usage** | `sensor.<node>_cpu_usage` | `%` (measurement) | Accurate CPU load percentage calculated from `/proc/stat` |
| **CPU Temperature** | `sensor.<node>_cpu_temperature` | `temperature` (`°C`) | Live SoC thermal reading from `/sys/class/thermal` |
| **Memory Usage** | `sensor.<node>_memory_usage` | `%` (measurement) | RAM consumption percentage from `/proc/meminfo` |
| **Memory Used** | `sensor.<node>_memory_used` | `data_size` (`MB`) | Physical RAM utilized in megabytes |
| **Last Boot** | `sensor.<node>_last_boot` | `timestamp` | UTC boot timestamp formatted to relative uptime |
| **VRRP Status** | `sensor.<node>_vrrp_status` | Text (`MASTER` / `BACKUP`) | Keepalived failover state with `virtual_ip` attribute |
| **Services Health** | `sensor.<node>_services_health` | Text (`HEALTHY (X/X active)`) | Cluster daemon health aggregation via `rpi-services-status` |
| **Update Available** | `binary_sensor.<node>_update_available` / `update.<node>_update` | `update` | Tracks GitHub repo updates via `rpi-check-update` (cached 12h) |

### Availability & Offline Detection

The monitor publishes availability to `rpi/<node>/availability` (`online` / `offline`). In addition, each sensor is configured with `expire_after: 180`, ensuring that if a node suffers sudden power loss or network disruption, Home Assistant immediately transitions its sensors to `Unavailable` within 3 minutes while tolerating transient broker restarts without flapping.

### MQTT Broker Configuration (`/persist/secrets/mqtt.env`)

Broker connection details are kept strictly out of Git and stored in persistent storage on each Pi (`/persist/secrets/mqtt.env`):

```bash
MQTT_HOST=192.168.1.X
MQTT_PORT=1883
MQTT_USER=
MQTT_PASS=
```

To update or configure broker credentials at any time:
```bash
# On either Pi:
sudo nano /persist/secrets/mqtt.env
sudo rpi-persist-save secrets
sudo systemctl restart rpi-mqtt-monitor
```
