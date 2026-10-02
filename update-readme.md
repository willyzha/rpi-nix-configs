# Applying Updates (Full Documentation)

This document provides a deep dive into the update mechanics for the Raspberry Pi NixOS cluster.

## How the Docker Rebuild Workflow Operates

When you use the `./docker-rebuild.sh` script or the `docker run` command, the following lifecycle occurs:

1. **Automatic ARM64 Emulation**: Uses `tonistiigi/binfmt` to register `qemu-aarch64` in the kernel so any `aarch64` derivation can run seamlessly on your `x86_64` host.
2. **Persistent Store Cache**: Mounts named volume `rpi-nix-store` and `rpi-nix-cache` so packages and flakes downloaded once are cached permanently across rebuilds.
3. **Pre-flight Connectivity Check**: Tests SSH authentication with `root@$TARGET_IP` before compiling anything.
4. **SD Protection RW Remount**: Automatically remounts the target's `/` and `/boot/firmware` partitions as `rw` over SSH so the store paths can be received.
5. **Host-Side Build**: Evaluates and builds the system toplevel using your host machine's full CPU and RAM in seconds.
6. **Network Closure Copy**: Pushes only the changed store paths to the Pi via `nix copy` over SSH.
7. **Clean Profile Activation**: Registers the new NixOS generation and executes `switch-to-configuration boot` (or `switch`).
8. **Restores Read-Only Protection & Reboots**: Automatically remounts the Pi's partitions back to Read-Only (`ro`), syncs disks, and (if `boot` action) initiates a clean reboot. Includes an automatic signal trap to ensure partitions are never left read-write if interrupted!

---

## Alternative Method: Native Rebuild Directly on the Pi (Standalone Fallback)

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
