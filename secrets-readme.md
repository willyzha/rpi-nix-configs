# Secrets Configuration Guide

All private credentials and tokens in this repository are strictly loaded from physical persistent storage (`/persist/secrets/`) via NixOS `environmentFile` bindings or systemd variables. **Nothing** is ever checked into Git.

While the new master `sudo rpi-onboard` script automates this for you, you can manually run these underlying wizards at any time to update individual credentials.

## Individual Setup Scripts


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

