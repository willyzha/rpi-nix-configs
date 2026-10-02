{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix # Assuming Pi 3 or 4; adapt if necessary
    ../../modules/docker.nix
  ];

  networking = {
    hostName = "pi-remote";
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  # 1. Eclipse Mosquitto MQTT Server (Native)
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        port = 1883;
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
      }
    ];
  };

  # 2. Tailscale (Native)
  services.tailscale = {
    enable = true;
  };

  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var/lib/tailscale";
    options = [ "bind" "nofail" "x-systemd.device-timeout=30s" "x-systemd.requires=persist.mount" "x-systemd.after=persist.mount" ];
    noCheck = true;
    depends = [ "/persist" ];
  };

  # 3. WireGuard (Native)
  # Uses wg-quick to load the configuration directly from the persistent secret file
  networking.wg-quick.interfaces = {
    wg0 = {
      configFile = "/persist/secrets/wg0.conf";
    };
  };

  # ---------------------------------------------------------------------------
  # Docker Containers
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {

      # SWAG (Nginx reverse proxy + Certbot)
      swag = {
        image = "ghcr.io/linuxserver/swag:latest";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/swag.env" ]; # Store DUCKDNSTOKEN here
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Toronto";
          URL = "ottawahome.duckdns.org";
          SUBDOMAINS = "wildcard";
          VALIDATION = "duckdns";
          DISABLE_F2B = "true";
        };
        volumes = [
          "/persist/docker/swag/config:/config"
          "/persist/docker/swag/logrotate/logrotate.conf:/etc/logrotate.conf"
          "/persist/docker/swag/logrotate/logrotate.d/fail2ban:/etc/logrotate.d/fail2ban"
          "/persist/docker/swag/logrotate/logrotate.d/lerotate:/etc/logrotate.d/lerotate"
          "/persist/docker/swag/logrotate/logrotate.d/nginx:/etc/logrotate.d/nginx"
          "/persist/docker/swag/logrotate/logrotate.d/php-fpm:/etc/logrotate.d/php-fpm"
        ];
        ports = [ "443:443" ];
        extraOptions = [
          "--read-only"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
          "--tmpfs=/config/log:size=16M"
        ];
      };

      # Home Assistant Matter Hub
      matter-hub = {
        image = "ghcr.io/riddix/home-assistant-matter-hub:latest";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/matter-hub.env" ]; # Store ACCESS_TOKEN here
        environment = {
          HAMH_HOME_ASSISTANT_URL = "http://homeassistant.local:8123";
          HAMH_LOG_LEVEL = "info";
          HAMH_HTTP_PORT = "8482";
        };
        volumes = [
          "/persist/docker/ha-matter-hub:/data"
        ];
        extraOptions = [ "--network=host" ];
      };

      # Wyze Bridge
      wyze-bridge = {
        image = "idisposablegithub365/wyze-bridge";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/wyze-bridge.env" ]; # Store credentials/STREAM_AUTH here
        environment = {
          FILTER_NAMES = "Kitchen Cam";
          WB_AUTH = "False";
          MQTT_HOST = "127.0.0.1:1883"; # Pointed to local Mosquitto
        };
        # Ports are ignored by docker when network=host is used
        extraOptions = [ "--network=host" ];
      };

      # Room Assistant
      room-assistant = {
        image = "mkerix/room-assistant:2.20.0";
        autoStart = true;
        volumes = [
          "/var/run/dbus:/var/run/dbus"
          "/persist/docker/roomassistant/config:/room-assistant/config"
        ];
        extraOptions = [ 
          "--network=host"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
        ];
      };

    };
  };

  # ---------------------------------------------------------------------------
  # Restic Backups
  # ---------------------------------------------------------------------------
  services.restic.backups.persist = {
    initialize = true;
    repository = "rclone:dropbox:backups/pi-remote";
    rcloneConfigFile = "/persist/secrets/rclone.conf";
    passwordFile = "/persist/secrets/restic-password";
    paths = [
      "/persist"
    ];
    exclude = [
      "/persist/var/lib/docker"
    ];
    extraBackupArgs = [
      "--no-cache"
    ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
    };
    pruneOpts = [
      "--keep-daily 3"
      "--keep-weekly 2"
      "--keep-monthly 1"
    ];
  };

  systemd.services."restic-backups-persist".serviceConfig.ExecStopPost = [
    "-/bin/sh -c 'if [ \"$SERVICE_RESULT\" = \"success\" ]; then mkdir -p /persist/var/cache/restic && date -u +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success; fi'"
  ];

  system.stateVersion = "24.05";
}
