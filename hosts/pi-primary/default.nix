{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
  ];

  networking = {
    hostName = "pi-primary";
    interfaces.eth0 = {
      ipv4.addresses = [{
        address = "192.168.1.11";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.1.1";
    nameservers = [ "127.0.0.1" "1.1.1.1" ];
    firewall.checkReversePath = "loose"; # Required for Tailscale subnet router/exit node
  };

  # ---------------------------------------------------------------------------
  # State Persistence for Native Services (Bind-mounted from /persist)
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var/lib/tailscale";
    options = [ "bind" ];
    noCheck = true;
  };

  fileSystems."/var/lib/AdGuardHome" = {
    device = "/persist/var/lib/AdGuardHome";
    options = [ "bind" ];
    noCheck = true;
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services (Substantially saves RAM on 1 GB Pi 3B)
  # ---------------------------------------------------------------------------

  # 1. Tailscale Subnet Router & Exit Node (~20MB RAM, no container overhead)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [
      "--advertise-routes=192.168.2.0/24"
      "--advertise-exit-node"
      "--accept-routes"
    ];
  };

  # 2. AdGuard Home (~15MB RAM, replaces Pi-hole, web UI on port 3000)
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    port = 3000; # Web UI accessible at http://192.168.1.11:3000
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          "8.8.8.8"
          "1.1.1.1"
        ];
      };
      querylog = {
        enabled = true;
        interval = "24h";
        size_memory = 1000;
      };
    };
  };

  # 3. Keepalived VRRP Master (~4MB RAM, monitors port 443 for SWAG)
  services.keepalived = {
    enable = true;
    vrrpScripts.check_swag = {
      script = "${pkgs.iproute2}/bin/ss -tlpn | grep -q :443";
      interval = 2;
      weight = 2;
    };
    vrrpInstances.VI_1 = {
      interface = "eth0";
      state = "MASTER";
      virtualRouterId = 51;
      priority = 105;
      virtualIps = [
        { addr = "192.168.1.9/24"; }
      ];
      trackScripts = [ "check_swag" ];
      # Auth config loaded from persistent untracked secret file if present
      extraConfig = ''
        include /persist/secrets/keepalived-auth.conf
      '';
    };
  };

  # 4. Network UPS Tools (NUT) Server (~4MB RAM, CyberPower PR1500LCDRT2U)
  power.ups = {
    enable = true;
    mode = "standalone";
    ups."cyberpower" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower PR1500LCDRT2U";
      extraConfig = ''
        vendorid = 0764
        productid = 0601
        pollonly
      '';
    };
    upsd = {
      enable = true;
      listen = [
        { address = "0.0.0.0"; port = 3493; }
      ];
    };
  };

  # 5. Glances System Monitor (~45MB RAM, runs natively via systemd)
  systemd.services.glances = {
    description = "Glances System Monitor";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.glances}/bin/glances -w -p 61208";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # ---------------------------------------------------------------------------
  # Remaining Docker Containers (Kept in Docker per configuration)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # Portainer CE
      portainer = {
        image = "portainer/portainer-ce:alpine";
        autoStart = true;
        ports = [
          "8000:8000"
          "9000:9000"
        ];
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock"
          "/persist/docker/portainer/data:/data"
        ];
      };

      # SWAG (Nginx reverse proxy + Certbot)
      swag = {
        image = "ghcr.io/linuxserver/swag:latest";
        autoStart = true;
        ports = [
          "443:443"
        ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          URL = "example.com";
          SUBDOMAINS = "wildcard";
          VALIDATION = "dns";
          DNSPLUGIN = "cloudflare";
          PROPAGATION = "30";
          EMAIL = "admin@example.com";
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
      };

      # UPS Wake-on-LAN client (connects to native NUT server on localhost:3493)
      upswake = {
        image = "thedarthmole/upswake:latest";
        autoStart = true;
        extraOptions = [
          "--network=host"
          "--read-only"
        ];
        volumes = [
          "/persist/docker/nut_server/upswake/upswake-config.yaml:/config.yaml:ro"
          "/persist/docker/nut_server/upswake/upswake-rules:/rules/:ro"
        ];
        cmd = [ "serve" ];
      };

      # Python DLight MQTT bridge
      python-container = {
        image = "python:3";
        autoStart = true;
        environment = {
          TZ = "America/Los_Angeles";
          MQTT_ADDR = "192.168.1.10";
          DLIGHT_ADDR = "192.168.1.39";
        };
        volumes = [
          "/persist/docker/python_container:/usr/src/scripts"
        ];
        extraOptions = [
          "--network=host"
        ];
        cmd = [ "sh" "/usr/src/scripts/run.sh" ];
      };

      # Rclone GUI & sync
      rclone = {
        image = "rclone/rclone:latest";
        autoStart = true;
        ports = [
          "5572:5572"
        ];
        environment = {
          TZ = "America/Los_Angeles";
          PUID = "1000";
          PGID = "1000";
        };
        volumes = [
          "/persist/docker/rclone/config:/config"
          "/persist/docker/rclone/downloads:/downloads"
          "/persist/home/pi:/data:ro"
        ];
        extraOptions = [
          "--network=host"
        ];
        cmd = [
          "-c"
          "crond && crontab /config/synccron && rclone rcd --rc-web-gui --rc-addr :5572 --rc-user admin --rc-pass /persist/secrets/rclone-pass"
        ];
      };
    };
  };

  system.stateVersion = "24.05";
}
