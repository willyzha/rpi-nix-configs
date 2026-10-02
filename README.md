# Raspberry Pi NixOS Configurations

Declarative NixOS configurations for Raspberry Pi nodes, built with **zero-wear SD card protection** using read-only system partitions, an OverlayFS RAM layer on `/persist`, and seamless atomic updates.

---

## Hosts & Services Architecture

### `kir-pi-primary` (`kir-pi-primary.local` - Raspberry Pi 3 Model B)
- **Native Services**:
  - [**AdGuard Home**](https://github.com/AdguardTeam/AdGuardHome): Local DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - [**Tailscale**](https://tailscale.com/): Mesh VPN with subnet routing (`192.168.2.0/24`) and exit node support.
  - [**Keepalived**](https://www.keepalived.org/): VRRP non-preemptive sticky failover (`priority 105`, VMAC `vrrp.51`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - [**NUT Server**](https://networkupstools.org/): Network UPS Tools daemon for CyberPower PR1500LCDRT2U battery backup (Port `3493`).
  - [**MQTT Telemetry Monitor**](monitoring-readme.md): Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, VRRP role, and service health.
  - [**Restic Backup**](https://restic.net/): Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:00` daily timer).
- **Docker Containers**:
  - [**SWAG**](https://github.com/linuxserver/docker-swag): Reverse proxy with automated SSL certificate generation (Port `443`).
  - [**UPSWake**](https://github.com/TheDarthMole/UPSWake): Wake-on-LAN service polling NUT server status.

### `kir-pi-secondary` (`kir-pi-secondary.local` - Raspberry Pi 3 Model B)
- **Native Services**:
  - [**WireGuard**](https://www.wireguard.com/): VPN server running via kernel module (Port `51820/udp`, `10.13.13.1/24`).
  - [**AdGuard Home**](https://github.com/AdguardTeam/AdGuardHome): Secondary DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - [**Keepalived**](https://www.keepalived.org/): VRRP non-preemptive sticky failover (`priority 100`, VMAC `vrrp.51`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - [**MQTT Telemetry Monitor**](monitoring-readme.md): Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, VRRP role, and service health.
  - [**Restic Backup**](https://restic.net/): Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:30` daily timer).
- **Docker Containers**:
  - [**SWAG**](https://github.com/linuxserver/docker-swag): Failover reverse proxy (Port `443`).

### `ott-pi-primary` (Remote Node - Raspberry Pi 4 Model B)
- **Native Services**:
  - [**Eclipse Mosquitto**](https://mosquitto.org/): Native local MQTT Broker (Port `1883`).
  - [**Tailscale**](https://tailscale.com/): Mesh VPN with exit node support.
  - [**WireGuard**](https://www.wireguard.com/): Kernel VPN integration.
  - [**MQTT Telemetry Monitor**](monitoring-readme.md): Lightweight native Home Assistant telemetry reporter (`rpi-mqtt-monitor`) publishing CPU, memory, temperature, uptime, and service health.
  - [**Restic Backup**](https://restic.net/): Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:00` daily timer).
- **Docker Containers**:
  - [**SWAG**](https://github.com/linuxserver/docker-swag): Nginx reverse proxy with automated SSL certificate generation (Port `443`).
  - [**Home Assistant Matter Hub**](https://github.com/t0bst4r/home-assistant-matter-hub): Matter translation layer connecting custom entities to Home Assistant.
  - [**Wyze Bridge**](https://github.com/mrlt8/docker-wyze-bridge): Bridges Wyze cameras to WebRTC/RTSP local network streams.
  - [**Room Assistant**](https://github.com/mKeRix/room-assistant): Room-level presence tracking.

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


## SD Card Partitioning Layout

When formatting or flashing an SD card for these configurations, partition labels are used:

| Partition | Size | Type | Label | Mount Point | Options |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `1` | 30 MB | FAT32 | `FIRMWARE` | `/boot/firmware` | `ro,noatime` |
| `2` | ~3.7 GB | ext4 | `NIXOS_SD` | `/` (root) | `ro,noatime` |
| `3` | Remaining (~26 GB) | ext4 | `PERSIST` | `/persist-raw` (backing for `/persist` OverlayFS) | `noatime` |

---

## Applying Updates

Building directly on a Raspberry Pi can trigger OOM crashes and heavy SD card swap wear. Instead, we use a containerized cross-compilation environment that builds the system closure on your fast x86_64 host and deploys it over SSH.

> **Note:** For a deep dive into the update mechanics, fallback standalone on-device builds (`sudo rpi-rebuild`), and how the zero-wear lifecycle scripts work under the hood, see the [Full Update Documentation (update-readme.md)](update-readme.md).

### Method 1: Build & Deploy via Local Repository

If you have cloned this repository, use the convenient wrapper script:

<details>
<summary><b>Deploy to <code>kir-pi-primary</code></b></summary>

```bash
# Auto-detect, build, and deploy (reboots when done):
./docker-rebuild.sh kir-pi-primary.local

# Switch services immediately without rebooting:
./docker-rebuild.sh kir-pi-primary.local switch
```

</details>

<details>
<summary><b>Deploy to <code>kir-pi-secondary</code></b></summary>

```bash
# Auto-detect, build, and deploy (reboots when done):
./docker-rebuild.sh kir-pi-secondary.local

# Switch services immediately without rebooting:
./docker-rebuild.sh kir-pi-secondary.local switch
```

</details>

<details>
<summary><b>Deploy to <code>ott-pi-primary</code></b></summary>

```bash
# Auto-detect, build, and deploy (reboots when done):
./docker-rebuild.sh ott-pi-primary.local

# Switch services immediately without rebooting:
./docker-rebuild.sh ott-pi-primary.local switch
```

</details>

### Method 2: Zero-Repo Deployment

You do **not** need to clone this repository to deploy updates! By using `docker run` directly, the container automatically pulls the latest `main` branch configuration straight from GitHub. 

*(Note: The `/tmp/rpi-nix-store` and `/tmp/rpi-nix-cache` paths bind-mount to your host's temporary directory. This prevents permanent storage bloat on your machine, but means the cache will be cleared when your host reboots. If your host's `/tmp` is a RAM-disk, ensure you have at least 4GB of free RAM to hold the Nix build closure!)*

<details>
<summary><b>Deploy to <code>kir-pi-primary</code></b></summary>

```bash
docker run --rm --net=host \
  -v ~/.ssh:/root/.ssh:ro \
  -v ${SSH_AUTH_SOCK:-/dev/null}:/ssh-agent:ro \
  -v /tmp/rpi-nix-store:/nix \
  -v /tmp/rpi-nix-cache:/root/.cache \
  ghcr.io/willyzha/rpi-nix-builder:latest kir-pi-primary.local
```

</details>

<details>
<summary><b>Deploy to <code>kir-pi-secondary</code></b></summary>

```bash
docker run --rm --net=host \
  -v ~/.ssh:/root/.ssh:ro \
  -v ${SSH_AUTH_SOCK:-/dev/null}:/ssh-agent:ro \
  -v /tmp/rpi-nix-store:/nix \
  -v /tmp/rpi-nix-cache:/root/.cache \
  ghcr.io/willyzha/rpi-nix-builder:latest kir-pi-secondary.local
```

</details>

<details>
<summary><b>Deploy to <code>ott-pi-primary</code></b></summary>

```bash
docker run --rm --net=host \
  -v ~/.ssh:/root/.ssh:ro \
  -v ${SSH_AUTH_SOCK:-/dev/null}:/ssh-agent:ro \
  -v /tmp/rpi-nix-store:/nix \
  -v /tmp/rpi-nix-cache:/root/.cache \
  ghcr.io/willyzha/rpi-nix-builder:latest ott-pi-primary.local
```

</details>

---

---

## Initial Installation on Fresh Raspberry Pi

Initial setup is fully automated using flashable SD card images released directly by GitHub Actions.

### Method 1: Burn Pre-Built Image (Recommended)

1. **Download Image**:
   - Go to your repository's **Releases** tab on GitHub (or the **Actions** tab artifacts).
   - Download the image for your target node:
     - `kir-pi-primary-nixos.img.zst` (for `kir-pi-primary.local`)
     - `kir-pi-secondary-nixos.img.zst` (for `kir-pi-secondary.local`)
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
     ssh pi@kir-pi-primary.local
     ssh pi@kir-pi-secondary.local
     ssh pi@ott-pi-primary.local
     ```
5. **Configure Secrets**:
   Run the interactive master onboarding wizard. It will auto-detect which node you are on and securely prompt you for only the relevant API keys and passwords required for that node. It features auto-resume, so you can safely abort and rerun it at any time without losing progress.
   ```bash
   sudo rpi-onboard
   ```
   > **Note:** For a deeper breakdown of how the zero-wear persistence layer works, or how to manually update individual credentials later, see the [Secrets & Persistence Documentation (secrets-readme.md)](secrets-readme.md).

6. **Restart Affected Services & Test Backup**:
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

7. **Enable Tailscale (on `kir-pi-primary`)**:
   Authenticate Tailscale as a subnet router and exit node:
   ```bash
   sudo tailscale up --advertise-exit-node --accept-routes
   ```
   Open the displayed URL in your browser to approve the node in the Tailscale admin console. Once authenticated, node keys and identity are persisted in `/persist/var/lib/tailscale/` across reboots.

8. **Configure AdGuard Home (on `kir-pi-primary` and `kir-pi-secondary`)**:
   AdGuard Home runs natively on both nodes with persistent settings stored in `/persist/var/lib/AdGuardHome/`:
   - `kir-pi-primary` Web interface: `http://kir-pi-primary.local:3000`
   - `kir-pi-secondary` Web interface: `http://kir-pi-secondary.local:3000`
   - Cluster VIP Web interface: `http://192.168.1.9:3000`
   - DNS server port: `53` (answers queries on node IPs and the shared VIP `192.168.1.9`).


---

### Method 2: Triggering a New Image Build

Images are built automatically by GitHub Actions:
- **On Tag**: Push any version tag (e.g. `git tag v1.0.0 && git push --tags`) to trigger a build and publish a GitHub Release with the flashable images and checksums.
- **On Demand**: Go to the **Actions** tab in GitHub -> select **Build & Release Flashable SD Images** -> click **Run workflow** -> choose `kir-pi-primary`, `kir-pi-secondary`, `ott-pi-primary`, or `all`.