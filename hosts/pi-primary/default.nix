{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
    ../../modules/espresense-tracker.nix
  ];

  networking = {
    hostName = "pi-primary";
    firewall.checkReversePath = "loose"; # Required for Tailscale subnet router/exit node
  };

  # ---------------------------------------------------------------------------
  # State Persistence for Native Services (Bind-mounted from /persist)
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var/lib/tailscale";
    options = [ "bind" "nofail" "x-systemd.device-timeout=30s" "x-systemd.requires=persist.mount" "x-systemd.after=persist.mount" ];
    noCheck = true;
    depends = [ "/persist" ];
  };

  fileSystems."/var/lib/AdGuardHome" = {
    device = "/persist/var/lib/AdGuardHome";
    options = [ "bind" "nofail" "x-systemd.device-timeout=30s" "x-systemd.requires=persist.mount" "x-systemd.after=persist.mount" ];
    noCheck = true;
    depends = [ "/persist" ];
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services (Substantially saves RAM on 1 GB Pi 3B)
  # ---------------------------------------------------------------------------

  # 1. Tailscale Subnet Router & Exit Node (~20MB RAM, no container overhead)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [
      "--advertise-exit-node"
      "--stateful-filtering=false"
      "--accept-dns=false"
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

  # Disable DynamicUser so AdGuard Home uses /var/lib/AdGuardHome directly on read-only root
  systemd.services.adguardhome.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "root";
  };

  # 3. Keepalived VRRP Master (~4MB RAM, monitors port 443 for SWAG)
  services.keepalived = {
    enable = true;
    extraGlobalDefs = ''
      enable_script_security
      vrrp_garp_master_repeat 5
      vrrp_garp_master_refresh 60
    '';
    vrrpScripts.check_swag = {
      script = "${pkgs.iproute2}/bin/ss -tlpn | ${pkgs.gnugrep}/bin/grep -q :443";
      interval = 2;
      weight = -20;
      user = "root";
    };
    vrrpInstances.VI_1 = {
      interface = "eth0";
      state = "BACKUP";
      virtualRouterId = 51;
      priority = 105;
      unicastSrcIp = "192.168.1.11";
      unicastPeers = [ "192.168.1.12" ];
      virtualIps = [
        { addr = "192.168.1.9/24"; }
      ];
      trackScripts = [ "check_swag" ];
      # Auth config loaded from persistent untracked secret file if present
      extraConfig = ''
        include /persist/secrets/keepalived-auth.conf
        nopreempt
        use_vmac
        vmac_xmit_base
      '';
    };
  };

  # 4. Network UPS Tools (NUT) Server (~4MB RAM, CyberPower PR1500LCDRT2U)
  power.ups = {
    enable = true;
    mode = "netserver";
    upsmon.enable = false;
    ups."cyberpower" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower PR1500LCDRT2U";
      directives = [
        "vendorid = 0764"
        "productid = 0601"
        "pollonly"
      ];
    };
    upsd = {
      enable = true;
      listen = [
        { address = "0.0.0.0"; port = 3493; }
      ];
    };
    users.monuser = {
      passwordFile = "/persist/secrets/nut-monuser-password";
      upsmon = "master";
    };
  };


  # ---------------------------------------------------------------------------
  # Remaining Docker Containers (Kept in Docker per configuration)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # SWAG (Nginx reverse proxy + Certbot)
      swag = {
        image = "ghcr.io/linuxserver/swag:latest";
        autoStart = true;
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          SUBDOMAINS = "wildcard";
          VALIDATION = "dns";
          DNSPLUGIN = "cloudflare";
          PROPAGATION = "30";
          DISABLE_F2B = "true";
        };
        # Load sensitive domain URL and contact email from persistent secret file (untracked by git)
        environmentFiles = [
          "/persist/secrets/swag.env"
        ];
        volumes = [
          "/persist/docker/swag/config:/config"
          "/persist/docker/swag/logrotate/logrotate.conf:/etc/logrotate.conf"
          "/persist/docker/swag/logrotate/logrotate.d/fail2ban:/etc/logrotate.d/fail2ban"
          "/persist/docker/swag/logrotate/logrotate.d/lerotate:/etc/logrotate.d/lerotate"
          "/persist/docker/swag/logrotate/logrotate.d/nginx:/etc/logrotate.d/nginx"
          "/persist/docker/swag/logrotate/logrotate.d/php-fpm:/etc/logrotate.d/php-fpm"
        ];
        # Prevent runtime SD card writes: container root is read-only, logs & runtime in RAM
        # Uses --network=host to bind directly to ports 80/443 without Docker bridge or NAT conflicts with Tailscale
        extraOptions = [
          "--network=host"
          "--read-only"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
          "--tmpfs=/config/log:size=16M"
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

    };
  };

  # Native Restic backup of /persist to Dropbox via Rclone
  services.restic.backups.persist = {
    initialize = true;
    repository = "rclone:dropbox:backups/pi-primary";
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

  # ESPresense Simple Tracker
  services.espresense-tracker = {
    enable = true;
    mqttHost = "192.168.1.10";
    envFile = "/persist/secrets/espresense-tracker.env";
  };

  system.stateVersion = "24.05";
}
