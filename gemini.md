# Gemini Learnings & Best Practices

## Deployment (`docker-rebuild.sh`)
When deploying configurations using `docker-rebuild.sh`, **rely on the script's built-in auto-detection** instead of explicitly forcing the `TARGET_HOST` (either via positional arguments or exported environment variables).

**Correct Usage:**
```bash
# Provide only the IP address and let the script securely auto-detect the node's identity:
./docker-rebuild.sh 192.168.1.11 boot
./docker-rebuild.sh 192.168.1.12 boot
```

**Why?**
The deployment script is designed to SSH into the target IP, securely query its true hostname (`cat /proc/sys/kernel/hostname`), and automatically build the correct NixOS configuration for it. By explicitly forcing a `TARGET_HOST`, we bypass this safety mechanism, which can lead to flashing a node with the wrong configuration if there is an IP mixup or if bash variables leak between commands.

## Raspberry Pi specific quirks
* **No Hardware RTC:** Raspberry Pis do not have a Real-Time Clock. On boot, their clock will default to the epoch or the last fake-hwclock save until NTP synchronizes. 
  * *Lesson:* Any telemetry scripts calculating timestamps (like `last_boot`) must first verify NTP sync using `timedatectl show -p NTPSynchronized --value`. If it returns anything other than `yes`, omit the metric or send `null` to avoid publishing wildly inaccurate dates to Home Assistant.
