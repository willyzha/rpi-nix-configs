# Raspberry Pi NixOS Configurations

Declarative NixOS configurations for Raspberry Pi nodes, built with **zero-wear SD card protection** using an ephemeral `tmpfs` root, read-only system partitions, and seamless atomic updates.

---

## Hosts & Services Architecture

### `pi-primary` (`192.168.1.11` - Raspberry Pi 3 Model B)
- **Native Services**:
  - **AdGuard Home**: Local DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - **Tailscale**: Mesh VPN with subnet routing (`192.168.2.0/24`) and exit node support.
  - **Keepalived**: VRRP high-availability `MASTER` (Priority `105`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - **NUT Server**: Network UPS Tools daemon for CyberPower PR1500LCDRT2U battery backup (Port `3493`).
  - **Glances**: System and hardware resource monitoring daemon (Port `61208`).
  - **Restic Backup**: Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:00` daily timer).
- **Docker Containers**:
  - **SWAG**: Reverse proxy with automated SSL certificate generation (Port `443`).
  - **UPSWake**: Wake-on-LAN service polling NUT server status.

### `pi-secondary` (`192.168.1.12` - Raspberry Pi 3 Model B)
- **Native Services**:
  - **WireGuard**: VPN server running via kernel module (Port `51820/udp`, `10.13.13.1/24`).
  - **AdGuard Home**: Secondary DNS server and network-wide ad blocker (Port `53`, Web UI on port `3000`).
  - **Keepalived**: VRRP high-availability `BACKUP` (Priority `100`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - **Glances**: System and hardware resource monitoring daemon (Port `61208`).
  - **Restic Backup**: Automated daily snapshot backup of `/persist` to Dropbox via Rclone backend (`03:30` daily timer).
- **Docker Containers**:
  - **SWAG**: Failover reverse proxy (Port `443`).

---

## SD Card Zero-Wear Architecture

Traditional systems write continuously to the SD card (systemd journals, logrotate, atime updates, caches, container layers), which degrades flash cells and eventually causes corruption.

This setup prevents wear while preserving convenience:

```
┌────────────────────────────────────────────────────────┐
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
5. **`rpi-rebuild` command**: Built-in helper that automatically saves pending overlay changes, remounts `/` and `/boot/firmware` as `rw`, executes `nixos-rebuild`, and restores them to `ro` upon completion.
6. **`rpi-persist-save` command**: Built-in helper to commit modified files/directories from the `/persist` overlay down to physical SD card storage (`/persist-raw`).
7. **`rpi-check-update` command**: Built-in helper to check if the running system is in sync with the latest GitHub commit (with optional `--diff` support).

---

## Directory Structure

```
rpi-nix-configs/
├── .gitignore                        # Prevents secrets and build artifacts from git
├── flake.nix                         # Flake entry point (pi-primary & pi-secondary)
├── modules/
│   ├── sd-protection.nix             # Read-only root, OverlayFS, tmpfs mounts, rpi-persist-save, rpi-rebuild
│   ├── common.nix                    # Common base (user pi, ssh keys, zram, timezone, tools)
│   ├── hardware-rpi3.nix             # RPi 3B kernel and boot config
│   └── docker.nix                    # Docker daemon tuning & native ext4 data root
└── hosts/
    ├── pi-primary/
    │   └── default.nix               # AdGuard Home, Tailscale, NUT, Keepalived, SWAG
    └── pi-secondary/
        └── default.nix               # WireGuard, Keepalived, SWAG
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

### Native Rebuild Directly on the Pi (Zero Setup on Your Computer)

You do **not** need Nix, Docker, or any special tools installed on your computer. You can run the rebuild directly on the Pi via SSH:

```bash
# On either Pi (automatically detects pi-primary vs pi-secondary):
sudo rpi-rebuild

# Or remotely via SSH:
ssh pi@192.168.1.11 "sudo rpi-rebuild"
ssh pi@192.168.1.12 "sudo rpi-rebuild"
```

The built-in `rpi-rebuild` helper script automatically handles the entire lifecycle:
1. Remounts `/` and `/boot/firmware` as read-write (`rw`).
2. Ensures the `nix-daemon` service is active and listening.
3. **Temporarily stops Docker** (freeing ~500 MB of RAM so the Nix evaluation fits entirely in physical RAM without swap thrashing or CPU freezing).
4. Pulls the latest Git commit and rebuilds the NixOS generation.
5. **Trapped cleanup**: Automatically restarts Docker and restores partitions back down to zero-wear read-only (`ro,noatime`), even if interrupted or on error.

### Check If System Is Up to Date With GitHub

To check if your node is running the latest configuration from GitHub without rebuilding:
```bash
rpi-check-update

# To inspect exact /etc file differences if an update is available:
rpi-check-update --diff
```

---

## Initial Installation on Fresh Raspberry Pi

Initial setup is fully automated using flashable SD card images released directly by GitHub Actions.

### Method 1: Burn Pre-Built Image (Recommended)

1. **Download Image**:
   - Go to your repository's **Releases** tab on GitHub (or the **Actions** tab artifacts).
   - Download the image for your target node:
     - `pi-primary-nixos.img.zst` (for `192.168.1.11`)
     - `pi-secondary-nixos.img.zst` (for `192.168.1.12`)
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
     ssh pi@pi-primary.local    # or ssh pi@192.168.1.11
     ssh pi@pi-secondary.local  # or ssh pi@192.168.1.12
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

   - **NUT Server Monitoring Password** (for `pi-primary`, used by `upswake` and `upsd`):
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
     # On pi-primary:
     sudo systemctl restart keepalived
     sudo systemctl start restic-backups-persist.service

     # On pi-secondary:
     sudo systemctl restart keepalived wireguard-wg0
     sudo systemctl start restic-backups-persist.service

     # View backup logs:
     sudo journalctl -u restic-backups-persist.service -f

     # View snapshots:
     sudo RCLONE_CONFIG=/persist/secrets/rclone.conf restic -r rclone:dropbox:backups/pi-primary --password-file /persist/secrets/restic-password snapshots
     ```

6. **Enable Tailscale (on `pi-primary`)**:
   Authenticate Tailscale as a subnet router and exit node:
   ```bash
   sudo tailscale up --advertise-exit-node --accept-routes
   ```
   Open the displayed URL in your browser to approve the node in the Tailscale admin console. Once authenticated, node keys and identity are persisted in `/persist/var/lib/tailscale/` across reboots.

7. **Configure AdGuard Home (on `pi-primary`)**:
   AdGuard Home runs natively on `pi-primary` with configuration and stats persisted in `/persist/var/lib/AdGuardHome/`:
   - Web interface: `http://pi-primary.local:3000` (or `http://192.168.1.11:3000`)
   - DNS server port: `53`
   Complete the web setup wizard to configure blocklists and upstream DNS.

---

### Method 2: Triggering a New Image Build

Images are built automatically by GitHub Actions:
- **On Tag**: Push any version tag (e.g. `git tag v1.0.0 && git push --tags`) to trigger a build and publish a GitHub Release with the flashable images and checksums.
- **On Demand**: Go to the **Actions** tab in GitHub -> select **Build & Release Flashable SD Images** -> click **Run workflow** -> choose `pi-primary`, `pi-secondary`, or `both`.