import json
import logging
import os
import time
import threading
from datetime import datetime, timedelta
import paho.mqtt.client as mqtt

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("espresense_tracker")

class FlushHandler(logging.StreamHandler):
    def emit(self, record):
        super().emit(record)
        self.flush()
logger.handlers = [FlushHandler()]

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
MQTT_USER = os.getenv("MQTT_USER", "")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD", "")
MQTT_CLIENT_ID = os.getenv("MQTT_CLIENT_ID", "espresense_simple_tracker")

# Comma separated list of device IDs to track. E.g. "apple:1005:9-12|Willys iPad,tile:abcde"
# If set to "*", all discovered devices will be tracked (warning: can clutter Home Assistant)
raw_devices = [d.strip().strip('"').strip("'") for d in os.getenv("DEVICES", "").split(",") if d.strip()]
DEVICES_TO_TRACK = {}
for d in raw_devices:
    parts = d.split("|", 1)
    dev_id = parts[0].strip()
    dev_name = parts[1].strip() if len(parts) > 1 else f"ESPresense Tracker {dev_id}"
    DEVICES_TO_TRACK[dev_id] = dev_name

TRACK_ALL = "*" in DEVICES_TO_TRACK

NODE_TIMEOUT_SECONDS = int(os.getenv("NODE_TIMEOUT", os.getenv("TIMEOUT", 30)))
AWAY_TIMEOUT_SECONDS = int(os.getenv("AWAY_TIMEOUT", 120))
MAX_DISTANCE = float(os.getenv("MAX_DISTANCE", 15.0))
HA_DISCOVERY_PREFIX = os.getenv("HA_DISCOVERY_PREFIX", "homeassistant")
DISCOVERY_INTERVAL = int(os.getenv("DISCOVERY_INTERVAL", 300))

# State storage
# { device_id: { "nodes": { node_id: { "distance": float, "last_seen": datetime } }, "reported_state": str, "last_discovery": datetime } }
devices_state = {}
state_lock = threading.Lock()

def get_safe_id(device_id):
    return device_id.replace(":", "_").replace("-", "_").lower()

def publish_discovery(client, device_id):
    safe_id = get_safe_id(device_id)
    dev_name = DEVICES_TO_TRACK.get(device_id, f"ESPresense Tracker {device_id}")
    # Prepend espresense_simple_ to the topic to avoid conflicts with companion
    topic = f"{HA_DISCOVERY_PREFIX}/device_tracker/espresense_simple_{safe_id}/config"
    state_topic = f"espresense_simple_tracker/device_tracker/{safe_id}/state"
    attrs_topic = f"espresense_simple_tracker/device_tracker/{safe_id}/attributes"
    
    payload = {
        "has_entity_name": True,
        "state_topic": state_topic,
        "json_attributes_topic": attrs_topic,
        "source_type": "bluetooth_le",
        "unique_id": f"espresense_simple_{safe_id}",
        "device": {
            "identifiers": [f"espresense_simple_{safe_id}"],
            "name": dev_name,
            "manufacturer": "ESPresense Simple Tracker"
        }
    }
    client.publish(topic, json.dumps(payload), retain=True)
    logger.info(f"Published HA discovery for {device_id}")

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logger.info("Connected to MQTT broker")
        client.subscribe("espresense/devices/+/+")
    else:
        logger.error(f"Failed to connect to MQTT broker, return code: {rc}")

def on_message(client, userdata, msg):
    try:
        parts = msg.topic.split("/")
        if len(parts) < 4:
            return
        
        device_id = parts[2]
        node_id = parts[3]
        
        if not TRACK_ALL and device_id not in DEVICES_TO_TRACK:
            return
            
        logger.debug(f"Processing {device_id} at node {node_id}")

        payload = json.loads(msg.payload.decode('utf-8'))
        distance = payload.get("distance")
        
        if distance is None:
            return

        now = datetime.now()

        with state_lock:
            if device_id not in devices_state:
                devices_state[device_id] = {
                    "nodes": {},
                    "reported_state": None,
                    "last_discovery": datetime.min,
                    "last_seen_any": datetime.min
                }
            
            # Periodically re-publish discovery
            if (now - devices_state[device_id]["last_discovery"]).total_seconds() > DISCOVERY_INTERVAL:
                publish_discovery(client, device_id)
                devices_state[device_id]["last_discovery"] = now
                
            devices_state[device_id]["nodes"][node_id] = {
                "distance": distance,
                "last_seen": now
            }
            devices_state[device_id]["last_seen_any"] = now
            
            update_and_publish_state(client, device_id, now)

    except Exception as e:
        logger.error(f"Error processing message {msg.topic}: {e}")

def format_room_name(node_id):
    if not node_id or node_id == "not_home":
        return "not_home"
    return node_id.replace("_", " ").replace("-", " ").title()

def update_and_publish_state(client, device_id, now):
    state_info = devices_state[device_id]
    
    # Filter out nodes that haven't been seen recently or are too far
    valid_nodes = {}
    for node, data in list(state_info["nodes"].items()):
        if (now - data["last_seen"]).total_seconds() <= NODE_TIMEOUT_SECONDS:
            if data["distance"] <= MAX_DISTANCE:
                valid_nodes[node] = data
        elif (now - data["last_seen"]).total_seconds() > AWAY_TIMEOUT_SECONDS:
            # Clean up old nodes from memory
            del state_info["nodes"][node]
            
    if not valid_nodes:
        if (now - state_info.get("last_seen_any", datetime.min)).total_seconds() > AWAY_TIMEOUT_SECONDS:
            new_state = "not_home"
            closest_node = None
            closest_distance = None
        else:
            # Still within AWAY_TIMEOUT, keep last known state
            return
    else:
        # Find closest node
        closest_node = min(valid_nodes.keys(), key=lambda n: valid_nodes[n]["distance"])
        closest_distance = valid_nodes[closest_node]["distance"]
        new_state = format_room_name(closest_node)
        
    if new_state != state_info["reported_state"]:
        logger.info(f"Device {device_id} changed state: {state_info['reported_state']} -> {new_state}")
        state_info["reported_state"] = new_state
        
        safe_id = get_safe_id(device_id)
        state_topic = f"espresense_simple_tracker/device_tracker/{safe_id}/state"
        attrs_topic = f"espresense_simple_tracker/device_tracker/{safe_id}/attributes"
        
        client.publish(state_topic, new_state, retain=True)
        
        attrs = {
            "closest_node": closest_node,
            "distance": closest_distance,
            "updated_at": now.isoformat()
        }
        client.publish(attrs_topic, json.dumps(attrs), retain=True)

def timeout_check_loop(client):
    while True:
        try:
            time.sleep(10)
            now = datetime.now()
            with state_lock:
                for device_id in list(devices_state.keys()):
                    update_and_publish_state(client, device_id, now)
        except Exception as e:
            logger.error(f"Error in timeout loop: {e}")

if __name__ == "__main__":
    if not DEVICES_TO_TRACK and not TRACK_ALL:
        logger.warning("No DEVICES specified to track, and TRACK_ALL is not enabled. The script won't track anything.")

    client = mqtt.Client(client_id=MQTT_CLIENT_ID)
    if MQTT_USER:
        client.username_pw_set(MQTT_USER, MQTT_PASSWORD)
        
    client.on_connect = on_connect
    client.on_message = on_message

    logger.info(f"Connecting to MQTT Broker at {MQTT_HOST}:{MQTT_PORT}...")
    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, 60)
            break
        except Exception as e:
            logger.error(f"Connection failed: {e}. Retrying in 5 seconds...")
            time.sleep(5)

    # Start the timeout checker thread
    timeout_thread = threading.Thread(target=timeout_check_loop, args=(client,), daemon=True)
    timeout_thread.start()

    client.loop_forever()
