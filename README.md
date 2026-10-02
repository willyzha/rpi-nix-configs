# Raspberry Pi NixOS Configurations

Declarative NixOS configurations for Raspberry Pi nodes, built with **zero-wear SD card protection** using read-only system partitions, an OverlayFS RAM layer on `/persist`, and seamless atomic updates.

---

## Hosts & Services Architecture

### `kir-pi-primary` (`192.168.1.11` - Raspberry Pi 3 Model B)
- **Native Services**:
  - **AdGuard Home**: Local DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - **Tailscale**: Mesh VPN with subnet routing (`192.168.2.0/24`) and exit node support.
  - **Keepalived**: VRRP non-preemptive sticky failover (`priority 105`, VMAC `vrrp.51`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - **NUT Server**: Network UPS Tools daemon for CyberPower PR1500LCDRT2U battery backup (Port `3493`).
  - **MQTT Telemetry Monitor**: Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, VRRP role, and service health.
  - **Restic Backup**: Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:00` daily timer).
- **Docker Containers**:
  - **SWAG**: Reverse proxy with automated SSL certificate generation (Port `443`).
  - **UPSWake**: Wake-on-LAN service polling NUT server status.

### `kir-pi-secondary` (`192.168.1.12` - Raspberry Pi 3 Model B)
- **Native Services**:
  - **WireGuard**: VPN server running via kernel module (Port `51820/udp`, `10.13.13.1/24`).
  - **AdGuard Home**: Secondary DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - **Keepalived**: VRRP non-preemptive sticky failover (`priority 100`, VMAC `vrrp.51`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - **MQTT Telemetry Monitor**: Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, VRRP role, and service health.
  - **Restic Backup**: Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:30` daily timer).
- **Docker Containers**:
  - **SWAG**: Failover reverse proxy (Port `443`).

### `ott-pi-primary` (Remote Node - Raspberry Pi 4 Model B)
- **Native Services**:
  - **Eclipse Mosquitto**: Native local MQTT Broker (Port `1883`).
  - **Tailscale**: Mesh VPN with exit node support.
  - **WireGuard**: Kernel VPN integration.
  - **MQTT Telemetry Monitor**: Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, and service health.
  - **Restic Backup**: Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:00` daily timer).
- **Docker Containers**:
  - **SWAG**: Nginx reverse proxy with automated SSL certificate generation (Port `443`).
  - **Home Assistant Matter Hub**: Matter translation layer connecting custom entities to Home Assistant.
  - **Wyze Bridge**: Bridges Wyze cameras to WebRTC/RTSP local network streams.
  - **Room Assistant**: Room-level presence tracking.

---

## SD Card Zero-Wear Architecture

Traditional systems write continuously to the SD card (systemd journals, logrotate, atime updates, caches, container layers), which degrades flash cells and eventually causes corruption.

This setup prevents wear while preserving convenience:

```
┌────────────────────────────────────────────────────────────┐
│                        RAM (Volatile)                      │
│  ├─ /tmp (tmpfs, 256MB)        <── Temporary files         │
│  ├─ /var/cache (tmpfs, 64M)    <── Ephemeral service cache │
│  ├─ journald (volatile)        <── In-memory logs (32MB)   │
│  └─ /persist (OverlayFS)       <── Volatile upper layer    │
│       ├─ Accidental & runtime writes absorbed into RAM     │
│       └─ 'rpi-persist-save' explicitly commits to SD card  │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│                      SD CARD (Physical Flash)              │
│  ├─ /boot/firmware             <── Read-Only (vfat)        │
│  ├─ / (root filesystem)        <── Read-Only (ext4)        │
│  └─ /persist-raw (ext4)        <── Lower layer for /persist│
│       ├─ /persist-raw/etc/ssh/ (host keys)                 │
│       ├─ /persist-raw/var/lib/docker/ (container storage)  │
│       └─ /persist-raw/secrets/ (passwords & keys)          │
└────────────────────────────────────────────────────────────┘
```

1. **Read-Only Root (`/`) and Firmware (`/boot/firmware`)**: The entire root filesystem and boot firmware are mounted read-only (`ro,noatime`). No runtime execution writes to the SD card.
2. **Volatile RAM for Ephemeral State**: `/tmp`, `/var/cache`, and systemd journals live entirely in RAM (`tmpfs`), allowing services with `CacheDirectory=` (like Tailscale) to operate normally without flash wear.
3. **OverlayFS on `/persist` with Zero Accidental SD Writes**: The `/persist` mount is backed by an OverlayFS. Runtime writes (logs, temporary container files, accidental writes) are absorbed into volatile RAM (`tmpfs`). Only explicit commits via `rpi-persist-save` (or built-in setup wizards) write to the physical SD card (`/persist-raw`).
4. **Automated First-Boot Persistence**: The `PERSIST` partition is automatically created, formatted, and initialized on first boot, filling the remaining capacity of the SD card.
5. **`rpi-rebuild` command**: Built-in helper that auto-detects the host, checks network and disk space, allocates temporary 2GB swap on `/persist-raw`, reclaims RAM by stopping heavy services, executes `nixos-rebuild`, restores read-only mounts, and reboots cleanly (with automatic rollback on failure).
6. **`rpi-persist-save` command**: Built-in helper to commit modified files/directories from the `/persist` overlay down to physical SD card storage (`/persist-raw`). Detects identical contents to prevent unnecessary flash writes.
7. **`rpi-check-update` command**: Built-in helper that checks if the running system is in sync with the latest GitHub commit in ~0.3s via the Git wire protocol.
8. **`rpi-vrrp-status` command**: Built-in helper that queries local network interfaces to report whether the node is `MASTER` or `BACKUP` for Keepalived.
9. **`rpi-services-status` command**: Built-in helper that verifies the health of all cluster services (`keepalived`, `adguardhome`, `docker`, `docker-swag`, `rpi-mqtt-monitor`, `upsd`, `tailscaled`).

---

## Directory Structure

```
rpi-nix-configs/
├── .env.example                      # Configuration template for Docker deployments
├── .gitignore                        # Prevents secrets and build artifacts from git
├── docker-compose.yml                # Host-side Docker Compose setup for building & deploying
├── docker-rebuild.sh                 # Convenient 1-line rebuild wrapper script
├── flake.nix                         # Flake entry point (kir-pi-primary & kir-pi-secondary)
├── docker/
│   ├── Dockerfile                    # Containerized Nix build & deployment environment
│   ├── deploy.sh                     # Automated lifecycle script (RW remount, build, copy, switch, RO remount, reboot)
│   └── nix.conf                      # Optimized Nix config for cross-architecture builds & binary caching
├── modules/
│   ├── sd-protection.nix             # Read-only root, OverlayFS, tmpfs mounts, rpi-persist-save, rpi-rebuild
│   ├── common.nix                    # Common base (user pi, ssh keys, zram, VMAC sysctl, timezone, tools)
│   ├── mqtt-monitor.nix              # Native Home Assistant MQTT Auto-Discovery & telemetry reporter
│   ├── hardware-rpi3.nix             # RPi 3B kernel and boot config
│   ├── docker.nix                    # Docker daemon tuning & native ext4 data root
│   └── sd-image.nix                  # SD card image packaging with zstd compression
├── scripts/
│   ├── default.nix                   # Aggregates maintenance scripts into systemPackages
│   ├── rpi-rebuild.nix               # Automated host-aware rebuild lifecycle script
│   ├── rpi-persist-save.nix          # Overlay delta sync tool to physical SD card
│   ├── rpi-check-update.nix          # Instant git-based update checker
│   ├── rpi-vrrp-status.nix           # Live Keepalived VRRP role status script
│   ├── rpi-services-status.nix       # Real-time service health aggregation script
│   ├── rpi-set-password.nix          # User password setup wizard
│   ├── rpi-set-nut-password.nix      # NUT UPS monitor password setup wizard
│   ├── rpi-set-swag.nix              # SWAG reverse proxy setup wizard
│   ├── rpi-set-keepalived-auth.nix   # Keepalived authentication setup wizard
│   ├── rpi-set-restic-password.nix   # Restic backup password setup wizard
│   └── rpi-init-secrets.nix          # Secret directory initializer
└── hosts/
    ├── kir-pi-primary/
    │   └── default.nix               # AdGuard Home, Tailscale, NUT, Keepalived, MQTT Monitor, SWAG
    └── kir-pi-secondary/
        └── default.nix               # WireGuard, AdGuard Home, Keepalived, MQTT Monitor, SWAG
```

---

## SD Card Partitioning Layout

When formatting or flashing an SD card for these configurations, partition labels are used:

| Partition | Size | Type | Label | Mount Point | Options |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `1` | 30 MB | FAT32 | `FIRMWARE` | `/boot/firmware` | `ro,noatime` |
| `2` | ~3.7 GB | ext4 | `NIXOS_SD` | `/` (root) | `ro,noatime` |
| `3` | Remaining (~26 GB) | ext4 | `PERSIST` | `/persist-raw` (backing for `/persist` OverlayFS) | `noatime` |

---

## Applying Updates

### 🌟 Recommended Method: Host Rebuild via Docker (Zero RAM / Brownout Issues)

Building directly on a 1GB Raspberry Pi 3B often triggers **Out-Of-Memory (OOM) crashes**, excessive SD card swap wear, and **voltage drop brownouts** when high CPU spikes exceed micro-USB power delivery.

To solve this, a complete **Docker Compose environment** is included in the repository. It performs all evaluation, binary caching, and cross-architecture compilation on your host computer (fast CPU, plenty of RAM, NVMe speeds) and transfers only the finished system closure to the Pi over SSH.

> [!TIP]
> **Zero Host Dependencies**: You only need **Docker** and **Docker Compose** installed on your host. You do **not** need Nix, QEMU, Python, or any other tools installed locally.

#### Quick Start (Auto-Detect by IP)

Simply pass the IP address of the target Pi. The script queries the node over SSH, auto-detects whether it is `kir-pi-primary` or `kir-pi-secondary`, builds the appropriate configuration on your host, transfers the delta, and cleanly reboots it into the new generation:

```bash
# Update secondary Pi (auto-detects kir-pi-secondary):
./docker-rebuild.sh 192.168.1.12

# Update primary Pi (auto-detects kir-pi-primary):
./docker-rebuild.sh 192.168.1.11

# Or use hostname / compose directly:
./docker-rebuild.sh kir-pi-primary
./docker-rebuild.sh kir-pi-secondary
```

#### Common Commands & Options

| Command | Action Description |
| :--- | :--- |
| `./docker-rebuild.sh 192.168.1.12` | **(Default: `boot`)** Auto-detects node from IP, builds on host, copies closure, reboots node. |
| `./docker-rebuild.sh 192.168.1.12 switch` | Auto-detects node from IP, builds on host, and switches running services immediately (no reboot). |
| `./docker-rebuild.sh 192.168.1.12 test` | Tests build and activates services temporarily without modifying bootloader. |
| `./docker-rebuild.sh kir-pi-primary build-only` | Verifies and builds the NixOS system locally in Docker without connecting to the Pi (~2s cached). |
| `./docker-rebuild.sh kir-pi-primary image` | Generates the bootable SD card image (`.img.zst`) in `./output/` for fresh SD card flashing. |
| `docker compose run --rm shell` | Drops into an interactive bash shell in the Nix container for debugging. |

#### 🚀 Zero-Repo Deployment (Update without Git Checkout)

You do **not** even need to clone or check out this repository on your computer to deploy updates! When run without a mounted workspace, the container automatically pulls the latest configuration directly from `github:willyzha/rpi-nix-configs`:

```bash
docker run --rm --net=host \
  -v ~/.ssh:/root/.ssh:ro \
  -v ${SSH_AUTH_SOCK:-/dev/null}:/ssh-agent:ro \
  -v rpi-nix-store:/nix \
  -v rpi-nix-cache:/root/.cache \
  ghcr.io/willyzha/rpi-nix-builder:latest 192.168.1.12
```

*(Or use the locally cached image tag `rpi-nix-builder:latest`)*

#### How the Docker Rebuild Workflow Operates

1. **Automatic ARM64 Emulation**: Uses `tonistiigi/binfmt` to register `qemu-aarch64` in the kernel so any `aarch64` derivation can run seamlessly on your `x86_64` host.
2. **Persistent Store Cache**: Mounts named volume `rpi-nix-store` and `rpi-nix-cache` so packages and flakes downloaded once are cached permanently across rebuilds.
3. **Pre-flight Connectivity Check**: Tests SSH authentication with `root@$TARGET_IP` before compiling anything.
4. **SD Protection RW Remount**: Automatically remounts the target's `/` and `/boot/firmware` partitions as `rw` over SSH so the store paths can be received.
5. **Host-Side Build**: Evaluates and builds the system toplevel using your host machine's full CPU and RAM in seconds.
6. **Network Closure Copy**: Pushes only the changed store paths to the Pi via `nix copy` over SSH.
7. **Clean Profile Activation**: Registers the new NixOS generation and executes `switch-to-configuration boot` (or `switch`).
8. **Restores Read-Only Protection & Reboots**: Automatically remounts the Pi's partitions back to Read-Only (`ro`), syncs disks, and (if `boot` action) initiates a clean reboot. Includes an automatic signal trap to ensure partitions are never left read-write if interrupted!

---

### Alternative Method: Native Rebuild Directly on the Pi (Standalone Fallback)

If your host computer is unavailable, you can still run the rebuild directly on the Pi via SSH:

```bash
# On either Pi (automatically detects kir-pi-primary vs kir-pi-secondary):
sudo rpi-rebuild

# Or remotely via SSH:
ssh pi@192.168.1.11 "sudo rpi-rebuild"
ssh pi@192.168.1.12 "sudo rpi-rebuild"
```

The built-in `rpi-rebuild` helper script automatically handles the entire lifecycle:
1. **Pre-flight validation**: Checks for network connectivity, disk space (>=2.5GB free), and root privileges.
2. **Overlay save**: Commits any pending persistent changes from RAM to the physical SD card via `rpi-persist-save`.
3. **RAM reclamation**: Temporarily halts heavy services (Docker containers, AdGuard, rpi-mqtt-monitor, Keepalived, NUT) and drops filesystem caches to free ~700MB+ of real physical RAM.
4. **Temporary 2GB swap**: Dynamically allocates and enables a 2GB swap file on `/persist-raw` (secondary to zram) to guarantee OOM safety during heavy Nix evaluation. Aborts immediately if swap allocation fails to protect against kernel panics.
5. **Read-write remount & validation**: Remounts `/` as `rw` and verifies filesystem writability (detecting ext4 journal locks).
6. **Atomic generation build**: Rebuilds the system from GitHub using `--max-jobs 1 --cores 1`.
7. **Cleanup & reboot**: Automatically deactivates and removes the 2GB swapfile, restores read-only mounts, and reboots cleanly into the new generation.
8. **Automatic trapped rollback**: If any prerequisite or build step fails at any point, the script immediately rolls back, restarts all stopped services, removes the swapfile, and restores read-only mode.

### Check If System Is Up to Date With GitHub

To instantly check if your running system is in sync with GitHub without building:
```bash
rpi-check-update
```
*(Executes in ~0.3 seconds via Git wire protocol with zero RAM overhead).*

---

## Cluster Monitoring & Home Assistant Integration

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

---

## Initial Installation on Fresh Raspberry Pi

Initial setup is fully automated using flashable SD card images released directly by GitHub Actions.

### Method 1: Burn Pre-Built Image (Recommended)

1. **Download Image**:
   - Go to your repository's **Releases** tab on GitHub (or the **Actions** tab artifacts).
   - Download the image for your target node:
     - `kir-pi-primary-nixos.img.zst` (for `192.168.1.11`)
     - `kir-pi-secondary-nixos.img.zst` (for `192.168.1.12`)
     - `ott-pi-primary-nixos.img.zst` (for remote site)
2. **Burn to SD Card**:
   - Open **Raspberry Pi Imager** or **Balena Etcher**.
   - Select **Use Custom** -> choose the downloaded `.img.zst` file (Raspberry Pi Imager supports `.zst` directly).
   - Select your SD card and click **Write**.
3. **Power On**:
   - Insert the SD card into your Raspberry Pi and connect Ethernet.
   - Power on the Pi.
   - On first boot, the system automatically:
     - Detects the unallocated space on your SD card.
     - Partitions and formats `/persist` as ext4.
     - Generates persistent SSH host keys and initializes directory structures.
     - Boots into zero-wear read-only mode.
4. **SSH In**:
   - Connect immediately using your configured SSH key (via mDNS hostname or static IP):
     ```bash
     ssh pi@kir-pi-primary.local    # or ssh pi@192.168.1.11
     ssh pi@kir-pi-secondary.local  # or ssh pi@192.168.1.12
     ssh pi@ott-pi-primary.local
     ```
5. **Configure Secrets**:
   Set up your secrets under `/persist/secrets/` using the built-in helper scripts:

   - **Initialize / Verify Starter Secrets**:
     ```bash
     sudo rpi-init-secrets
     ```

   - **User Password** (for password login / local console):
     ```bash
     sudo rpi-set-password
     ```
     *(Automatically handles the read-write remount and writes to disk. Survives all future reboots and rebuilds).*

   - **NUT Server Monitoring Password** (for `kir-pi-primary`, used by `upswake` and `upsd`):
     ```bash
     sudo rpi-set-nut-password
     ```

   - **SWAG Reverse Proxy Setup (Domain, Email & Cloudflare Token)**:
     ```bash
     sudo rpi-set-swag
     ```
     *(Interactively prompts for your root domain, email, and Cloudflare token, saves them locally under `/persist/`, and restarts SWAG. Zero private data on Git).*

   - **Keepalived Cluster Authentication**:
     ```bash
     sudo rpi-set-keepalived-auth
     ```

   - **Restic Cloud Backup (Dropbox via Rclone)**:
     Set the encryption password:
     ```bash
     sudo rpi-set-restic-password
     ```
     Copy or create your `rclone.conf` containing your `[dropbox]` remote:
     ```bash
     sudo tee /persist/secrets/rclone.conf << 'EOF'
     [dropbox]
     type = dropbox
     token = {"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
     EOF
     sudo chmod 600 /persist/secrets/rclone.conf
     sudo rpi-persist-save secrets/rclone.conf
     ```

   - **Targeted Persistence & Saving Changes (`rpi-persist-save`)**:
     Because `/persist` is backed by an OverlayFS, all writes are safely absorbed into volatile RAM (`tmpfs`) to prevent SD card wear.
     - **Setup wizards** (`rpi-set-nut-password`, `rpi-set-swag`, etc.) only save their targeted password/config files.
     - **Certificate renewals** (`docker/swag/config/etc/letsencrypt`) are **automatically saved** to the SD card via a systemd path watcher whenever SWAG refreshes them.
     - **Manual saves**: You can target specific files or convenient shortcuts:
       ```bash
       # Targeted shortcuts:
       sudo rpi-persist-save certs       # Saves SWAG Let's Encrypt certificates
       sudo rpi-persist-save swag        # Saves SWAG proxy configs, DNS token, env
       sudo rpi-persist-save passwords   # Saves NUT, Keepalived, and Restic passwords
       sudo rpi-persist-save secrets     # Saves /persist/secrets directory

       # Specific files or directories:
       sudo rpi-persist-save secrets/rclone.conf
       sudo rpi-persist-save docker/swag/config/nginx/proxy-confs

       # Default targeted scan (only commits allowed persistent whitelist, ignores accidental writes):
       sudo rpi-persist-save
       ```

   - **Restart Affected Services & Test Backup**:
     ```bash
     # On kir-pi-primary:
     sudo systemctl restart keepalived
     sudo systemctl start restic-backups-persist.service

     # On kir-pi-secondary:
     sudo systemctl restart keepalived wireguard-wg0
     sudo systemctl start restic-backups-persist.service

     # View backup logs:
     sudo journalctl -u restic-backups-persist.service -f

     # View snapshots:
     sudo RCLONE_CONFIG=/persist/secrets/rclone.conf restic -r rclone:dropbox:backups/kir-pi-primary --password-file /persist/secrets/restic-password snapshots
     ```

6. **Enable Tailscale (on `kir-pi-primary`)**:
   Authenticate Tailscale as a subnet router and exit node:
   ```bash
   sudo tailscale up --advertise-exit-node --accept-routes
   ```
   Open the displayed URL in your browser to approve the node in the Tailscale admin console. Once authenticated, node keys and identity are persisted in `/persist/var/lib/tailscale/` across reboots.

7. **Configure AdGuard Home (on `kir-pi-primary` and `kir-pi-secondary`)**:
   AdGuard Home runs natively on both nodes with persistent settings stored in `/persist/var/lib/AdGuardHome/`:
   - `kir-pi-primary` Web interface: `http://192.168.1.11:3000` (or `http://kir-pi-primary.local:3000`)
   - `kir-pi-secondary` Web interface: `http://192.168.1.12:3000` (or `http://kir-pi-secondary.local:3000`)
   - Cluster VIP Web interface: `http://192.168.1.9:3000`
   - DNS server port: `53` (answers queries on node IPs and the shared VIP `192.168.1.9`).


---

### Method 2: Triggering a New Image Build

Images are built automatically by GitHub Actions:
- **On Tag**: Push any version tag (e.g. `git tag v1.0.0 && git push --tags`) to trigger a build and publish a GitHub Release with the flashable images and checksums.
- **On Demand**: Go to the **Actions** tab in GitHub -> select **Build & Release Flashable SD Images** -> click **Run workflow** -> choose `kir-pi-primary`, `kir-pi-secondary`, `ott-pi-primary`, or `all`.