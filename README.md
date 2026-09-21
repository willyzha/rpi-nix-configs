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
- **Docker Containers**:
  - **SWAG**: Reverse proxy with automated SSL certificate generation (Port `443`).
  - **Portainer**: Web interface for managing Docker containers (Ports `8000`, `9000`).
  - **UPSWake**: Wake-on-LAN service polling NUT server status.
  - **Python DLight**: MQTT integration bridge for smart lighting.
  - **Rclone**: Cloud storage synchronization service and web interface (Port `5572`).

### `pi-secondary` (`192.168.1.12` - Raspberry Pi 3 Model B)
- **Native Services**:
  - **WireGuard**: VPN server running via kernel module (Port `51820/udp`, `10.13.13.1/24`).
  - **Keepalived**: VRRP high-availability `BACKUP` (Priority `100`, VIP `192.168.1.9`) monitoring reverse proxy health.
  - **Glances**: System and hardware resource monitoring daemon (Port `61208`).
- **Docker Containers**:
  - **SWAG**: Failover reverse proxy (Port `443`).
  - **Portainer**: Web interface for managing Docker containers (Ports `8000`, `9000`).
  - **Rclone**: Cloud storage synchronization service and web interface (Port `5572`).

---

## SD Card Zero-Wear Architecture

Traditional systems write continuously to the SD card (systemd journals, logrotate, atime updates, caches, container layers), which degrades flash cells and eventually causes corruption.

This setup prevents wear while preserving convenience:

```
┌────────────────────────────────────────────────────────┐
│                        RAM                             │
│  ├─ / (tmpfs, 512MB)       <── All transient writes   │
│  ├─ /tmp (tmpfs, 256MB)    <── Temporary files         │
│  └─ journald (volatile)    <── In-memory logs (32MB)   │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│                      SD CARD                           │
│  ├─ /boot/firmware         <── Read-Only (vfat)        │
│  ├─ /nix                   <── Read-Only (ext4)        │
│  └─ /persist               <── Persistent (ext4)       │
│       ├─ /persist/etc/ssh/ (host keys)                 │
│       ├─ /persist/var/lib/tailscale/ (node state)      │
│       ├─ /persist/var/lib/AdGuardHome/ (DNS database)  │
│       ├─ /persist/var/lib/docker/ (containers)         │
│       └─ /persist/secrets/ (passwords & keys)          │
└────────────────────────────────────────────────────────┘
```

1. **Root on `tmpfs`**: The root filesystem lives entirely in RAM. Nothing written to `/etc`, `/var/log`, or `/tmp` ever touches the SD card.
2. **Read-Only `/nix` and `/boot/firmware`**: The Nix store and firmware partitions are mounted read-only (`ro`) and with `noatime`.
3. **No manual toggling**: Unlike Debian's `overlayroot` / `raspi-config`, you do **not** need to disable overlayfs, reboot, apt update, and reboot again.
4. **`rpi-rebuild` command**: Built-in helper that automatically remounts `/nix` and `/boot/firmware` as `rw`, executes `nixos-rebuild switch`, and restores them to `ro` upon completion.

---

## Directory Structure

```
rpi-nix-configs/
├── .gitignore                        # Prevents secrets and build artifacts from git
├── flake.nix                         # Flake entry point (pi-primary & pi-secondary)
├── modules/
│   ├── sd-protection.nix             # Ephemeral root, ro mounts, persist, rpi-rebuild
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

When formatting an SD card for these configurations, partition labels are used:

| Partition | Size | Type | Label | Mount Point | Options |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `1` | 512 MB | FAT32 | `FIRMWARE` | `/boot/firmware` | `ro,noatime` |
| `2` | 12 GB | ext4 | `NIXOS_SD` | `/nix` | `ro,noatime` |
| `3` | Remaining | ext4 | `PERSIST` | `/persist` | `rw,noatime` |

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
   - Connect immediately using your configured SSH key:
     ```bash
     ssh pi@192.168.1.11  # or pi@192.168.1.12
     ```
5. **Configure Secrets**:
   Set up your secrets under `/persist/secrets/` (these remain on the machine and are never tracked by Git):

   - **User Password Hash** (optional fallback if logging in with password instead of SSH key):
     ```bash
     mkpasswd -m sha-512 "your-chosen-password" | sudo tee /persist/secrets/pi-password-hash
     sudo chmod 600 /persist/secrets/pi-password-hash
     ```

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

   - **Restart Affected Services**:
     ```bash
     # On pi-primary:
     sudo systemctl restart keepalived

     # On pi-secondary:
     sudo systemctl restart keepalived wireguard-wg0
     ```

---

### Method 2: Triggering a New Image Build

Images are built automatically by GitHub Actions:
- **On Tag**: Push any version tag (e.g. `git tag v1.0.0 && git push --tags`) to trigger a build and publish a GitHub Release with the flashable images and checksums.
- **On Demand**: Go to the **Actions** tab in GitHub -> select **Build & Release Flashable SD Images** -> click **Run workflow** -> choose `pi-primary`, `pi-secondary`, or `both`.