# Gemini Learnings & Best Practices

## Deployment (`docker-rebuild.sh`)
When deploying configurations using `docker-rebuild.sh`, **always use positional arguments** instead of exporting environment variables, especially when deploying to multiple nodes sequentially.

**Correct Usage:**
```bash
./docker-rebuild.sh <TARGET_HOST> <ACTION> <TARGET_IP>
# Example:
./docker-rebuild.sh pi-primary boot 192.168.1.11
./docker-rebuild.sh pi-secondary boot 192.168.1.12
```

**Why?**
The script contains auto-detection logic that queries the target IP's current hostname. If you rely on environment variables (`export TARGET_HOST=...`), bash state can leak or the script may fall back to auto-detecting the wrong hostname if a node was previously misconfigured. Positional arguments explicitly override all detection logic and guarantee the correct NixOS configuration is built and applied to the intended IP address.

## Raspberry Pi specific quirks
* **No Hardware RTC:** Raspberry Pis do not have a Real-Time Clock. On boot, their clock will default to the epoch or the last fake-hwclock save until NTP synchronizes. 
  * *Lesson:* Any telemetry scripts calculating timestamps (like `last_boot`) must first verify NTP sync using `timedatectl show -p NTPSynchronized --value`. If it returns anything other than `yes`, omit the metric or send `null` to avoid publishing wildly inaccurate dates to Home Assistant.
