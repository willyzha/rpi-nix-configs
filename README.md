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
│                        RAM                             │
│  ├─ /tmp (tmpfs, 256MB)    <── Temporary files         │
│  ├─ /var/cache (tmpfs, 64M)<── Ephemeral service cache │
│  └─ journald (volatile)    <── In-memory logs (32MB)   │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│                      SD CARD                           │
│  ├─ /boot/firmware         <── Read-Only (vfat)        │
│  ├─ / (root filesystem)    <── Read-Only (ext4)        │
│  └─ /persist               <── Persistent (ext4)       │
│       ├─ /persist/etc/ssh/ (host keys)                 │
│       ├─ /persist/var/lib/tailscale/ (node state)      │
│       ├─ /persist/var/lib/AdGuardHome/ (DNS database)  │
│       ├─ /persist/var/lib/docker/ (containers)         │
│       └─ /persist/secrets/ (passwords & keys)          │
└────────────────────────────────────────────────────────┘
```

1. **Read-Only Root (`/`) and Firmware (`/boot/firmware`)**: The entire root filesystem and boot firmware are mounted read-only (`ro,noatime`). No runtime execution writes to the SD card.
2. **Volatile RAM for Ephemeral State**: `/tmp`, `/var/cache`, and systemd journals live entirely in RAM (`tmpfs`), allowing services with `CacheDirectory=` (like Tailscale) to operate normally without flash wear.
3. **Automated First-Boot Persistence**: The `PERSIST` partition is automatically created, formatted, and initialized on first boot, filling the remaining capacity of the SD card.
4. **`rpi-rebuild` command**: Built-in helper that automatically remounts `/` and `/boot/firmware` as `rw`, executes `nixos-rebuild switch`, and restores them to `ro` upon completion.

---

## Directory Structure

```
rpi-nix-configs/
├── .gitignore                        # Prevents secrets and build artifacts from git
├── flake.nix                         # Flake entry point (pi-primary & pi-secondary)
├── modules/
│   ├── sd-protection.nix             # Read-only root, tmpfs mounts, persist, rpi-rebuild
│   ├── common.nix                    # Common base (user pi, ssh keys, zram, timezone, tools)
│   ├── hardware-rpi3.nix             # RPi 3B kernel and boot config
│   └── docker.nix                    # Docker daemon tuning & persistent data root
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
| `3` | Remaining (~26 GB) | ext4 | `PERSIST` | `/persist` | `rw,noatime` |

---

## Applying Updates

To update or apply changes on a running Pi:

```bash
sudo rpi-rebuild switch .#pi-primary
```

The script safely handles:
1. `mount -o remount,rw /nix` and `mount -o remount,rw /boot/firmware`
2. `nixos-rebuild switch --flake .#pi-primary`
3. Trapped cleanup: `mount -o remount,ro /boot/firmware` and `mount -o remount,ro /nix`

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
   Set up your secrets under `/persist/secrets/` (these remain on the machine and are never tracked by Git):

   - **User Password** (optional fallback for password login / local console):
     Because root is read-only, temporarily remount `/` as read-write to set your password:
     ```bash
     sudo mount -o remount,rw /
     sudo passwd pi
     sudo mount -o remount,ro /
     ```
     Once set, your password is permanently saved in `/etc/shadow` on the ext4 partition, survives all future reboots, and will **not** be overwritten by NixOS updates or rebuilds.

   - **Keepalived Cluster Authentication**:
     ```bash
     sudo tee /persist/secrets/keepalived-auth.conf << 'EOF'
     authentication {
       auth_type PASS
       auth_pass your-cluster-password
     }
     EOF
     sudo chmod 600 /persist/secrets/keepalived-auth.conf
     ```

   - **WireGuard Server Key** (for `pi-secondary`):
     ```bash
     wg genkey | sudo tee /persist/secrets/wireguard/private.key
     sudo chmod 600 /persist/secrets/wireguard/private.key
     ```

   - **NUT Server Monitoring Password** (for `pi-primary`, used by `upswake` container to query `localhost:3493`):
     ```bash
     echo "your-nut-monuser-password" | sudo tee /persist/secrets/nut-monuser-password
     sudo chmod 600 /persist/secrets/nut-monuser-password
     ```

   - **Restic Cloud Backup (Dropbox via Rclone)**:
     Set up your Restic repository encryption password and Rclone config:
     ```bash
     # Set Restic encryption password:
     echo "your-strong-backup-password" | sudo tee /persist/secrets/restic-password
     sudo chmod 600 /persist/secrets/restic-password

     # Copy or create your rclone.conf containing your [dropbox] remote:
     sudo tee /persist/secrets/rclone.conf << 'EOF'
     [dropbox]
     type = dropbox
     token = {"access_token":"...","token_type":"bearer","refresh_token":"...","expiry":"..."}
     EOF
     sudo chmod 600 /persist/secrets/rclone.conf
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
     restic -r rclone:dropbox:backups/pi-primary --password-file /persist/secrets/restic-password snapshots
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