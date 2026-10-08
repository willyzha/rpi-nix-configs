# Gemini Learnings & Best Practices

## Deployment (`docker-rebuild.sh`)

### Auto-Detection
When deploying configurations using `docker-rebuild.sh`, **rely on the script's built-in auto-detection** instead of explicitly forcing the `TARGET_HOST` (either via positional arguments or exported environment variables).

**Correct Usage:**
```bash
# Provide only the IP address and let the script securely auto-detect the node's identity:
./docker-rebuild.sh 192.168.1.12 switch
./docker-rebuild.sh 192.168.1.11 switch
```

**Why?**
The deployment script is designed to SSH into the target IP, securely query its true hostname (`cat /proc/sys/kernel/hostname`), and automatically build the correct NixOS configuration for it. By explicitly forcing a `TARGET_HOST`, we bypass this safety mechanism, which can lead to flashing a node with the wrong configuration if there is an IP mixup or if bash variables leak between commands.

### Pre-Flight Testing
Before deploying any configuration or script change to physical nodes, **always run the in-container test suite**:
```bash
./docker-rebuild.sh test-container
```
This builds closures for all three nodes (`ott-pi-primary`, `kir-pi-primary`, `kir-pi-secondary`), tests NixOS activation scripts, runs `rpi-init-secrets`, verifies `rpi-onboard --check`, validates bash script syntax, and asserts systemd unit definitions without risking live hardware.

### Sequential Staged Rollout (Secondary First, Never Simultaneous)
When deploying updates to the high-availability Kirkland cluster (`kir-pi-primary` at `192.168.1.11` and `kir-pi-secondary` at `192.168.1.12`):
1. **Never deploy to both nodes simultaneously.** Keepalived VRRP requires at least one healthy node actively servicing the Virtual IP (`192.168.1.9`) and handling DNS/proxy traffic. Deploying both at once causes a full network blackout for the LAN.
2. **Deploy to Secondary First:**
   ```bash
   ./docker-rebuild.sh 192.168.1.12 switch
   ```
3. **Verify Secondary Health Before Touching Primary:**
   Ensure the secondary node is back up and completely healthy before initiating primary deployment:
   ```bash
   ssh root@192.168.1.12 "rpi-services-status"
   ```
   Verify that it reports `HEALTHY` and Keepalived is ready to take over the VIP if needed.
4. **Deploy to Primary Only After Secondary is Verified:**
   ```bash
   ./docker-rebuild.sh 192.168.1.11 switch
   ```
   After switching, verify the primary node:
   ```bash
   ssh root@192.168.1.11 "rpi-services-status"
   ```

## Raspberry Pi specific quirks
* **No Hardware RTC:** Raspberry Pis do not have a Real-Time Clock. On boot, their clock will default to the epoch or the last fake-hwclock save until NTP synchronizes. 
  * *Lesson:* Any telemetry scripts calculating timestamps (like `last_boot`) must first verify NTP sync using `timedatectl show -p NTPSynchronized --value`. If it returns anything other than `yes`, omit the metric or send `null` to avoid publishing wildly inaccurate dates to Home Assistant.

## Adding and Configuring a New Service

When an AI agent adds or configures a new service on any cluster node, it must strictly follow these principles:

### 1. Prefer Native NixOS Services Over Docker
* **Native First:** Always prefer native NixOS services (`services.<name>`) over Docker containers (`virtualisation.oci-containers`).
  * *Why?* Raspberry Pis (especially 1GB models like `kir-pi-primary` and `kir-pi-secondary`) have tight memory constraints (~400MB free). The Docker daemon, containerd shims, and container image layers introduce significant RAM and storage overhead. Native systemd services consume negligible memory, start instantly, and integrate seamlessly with NixOS's read-only filesystem architecture.
* **Docker as Fallback:** Only use Docker containers (`virtualisation.oci-containers.backend = "docker"`) when:
  * A native Nix package or service does not exist upstream or is unmaintained for ARM64.
  * The application requires complex multi-container dependencies or custom web assets that cannot be packaged cleanly in Nix.
* **SD Card Protection:** 
  * Ensure runtime state, logs, and volatile caches use `tmpfs` (e.g. systemd `RuntimeDirectory=`, `CacheDirectory=`, or explicit `fileSystems."<path>"` tmpfs mounts) or map to the `/persist` OverlayFS architecture. Never write unmanaged runtime data directly to the root filesystem.
* **Firewall Configuration:**
  * NixOS enforces an active firewall by default (`networking.firewall.enable = true`). If the service exposes a network port (HTTP UI, proxy, DNS, API), either enable the service's `openFirewall = true;` option or explicitly declare the ports in `networking.firewall.allowedTCPPorts` / `networking.firewall.allowedUDPPorts`.

### 2. Strictly Zero Secrets in Git
* **Never commit secrets:** Never commit personal API tokens, private keys, passwords, personal email addresses, or personal domain names into Git repository files (Nix configurations, documentation, comments, or commit history).
* **Use Placeholders in Repository:** Nix expressions, module templates, and tests must strictly use generic placeholders:
  * Domains: `example.com`, `*.example.com`
  * Passwords/keys: `changeme`, starter stubs
  * Emails: `admin@example.com`
* **Runtime Secret Location:** All live secrets must reside in `/persist/secrets/` on the target nodes with restricted permissions (`0600` for files, `0700` for directories).
* **Service Integration:** Use systemd's `EnvironmentFile = "/persist/secrets/<service>.env"` or `passwordFile = "/persist/secrets/<service>-password"` so secrets are injected dynamically at runtime without entering the Nix store or Git.

### 3. Setup Script & Onboarding Wizard Integration
Whenever a service requires an API token, password, domain, or node-specific secret:
* **Create a Dedicated Setup Script:** Add `scripts/rpi-set-<service>.nix` (following the pattern of [`scripts/rpi-set-cloudflare.nix`](file:///home/willyzha/code/rpi-nix-configs/scripts/rpi-set-cloudflare.nix)):
  * Support both interactive prompts (with masked inputs for tokens/passwords) and non-interactive CLI arguments.
  * Write the config/secret to `/persist/secrets/<service>.env` with `chmod 600`.
  * Call `rpi-persist-save` to commit the secret through the OverlayFS down to the physical SD card (`/persist-raw`).
  * Optionally trigger/restart the service and inspect `journalctl` to verify the configuration immediately on the live node.
* **Expose the Script:** Register the new script in [`scripts/default.nix`](file:///home/willyzha/code/rpi-nix-configs/scripts/default.nix) under `environment.systemPackages`.
* **Add Starter Stubs to `rpi-init-secrets`:** Update [`scripts/rpi-init-secrets.nix`](file:///home/willyzha/code/rpi-nix-configs/scripts/rpi-init-secrets.nix) so fresh nodes automatically initialize default starter placeholder files on boot.
* **Integrate with `rpi-onboard`:** Update [`scripts/rpi-onboard.nix`](file:///home/willyzha/code/rpi-nix-configs/scripts/rpi-onboard.nix):
  * In `is_placeholder()`, ensure any new placeholder patterns are recognized.
  * In `check_secret()`, add the new secret path to the `--check` status table for the relevant host(s).
  * In the main wizard flow, prompt the user or invoke the dedicated setup script to configure the secret.
* **Cluster Health Monitoring:** Register the service in [`scripts/rpi-services-status.nix`](file:///home/willyzha/code/rpi-nix-configs/scripts/rpi-services-status.nix) so its status is tracked by Home Assistant via MQTT:
  * **Long-running daemons** (e.g. `adguardhome`, `keepalived`, `mosquitto`): add to `CANDIDATES`.
  * **Timer-triggered services** (e.g. `cloudflare-dyndns`): add to `TIMER_CANDIDATES`. (Do NOT add timers to `CANDIDATES`, or they will falsely report `DEGRADED` while idle between runs).

### 4. Update the Readme
* Always update [`README.md`](file:///home/willyzha/code/rpi-nix-configs/README.md):
  * Document the new service under the appropriate host heading in `## Hosts & Services Architecture` (specify Native vs Docker, port, purpose).
  * Document the new setup script (`rpi-set-<service>`) in the maintenance/scripts section.
  * Document any required environment variables, default ports, and setup workflow.

