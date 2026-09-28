{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
  ];

  networking = {
    hostName = "pi-secondary";

    # In-Kernel WireGuard VPN server (0 MB daemon RAM, runs directly in Linux kernel)
    wireguard.interfaces.wg0 = {
      ips = [ "10.13.13.1/24" ];
      listenPort = 51820;
      # Load private key from persistent storage (untracked by git):
      # Generate with: wg genkey > /persist/secrets/wireguard/private.key
      privateKeyFile = "/persist/secrets/wireguard/private.key";
      peers = [
        # Example peer configuration:
        # {
        #   publicKey = "...";
        #   allowedIPs = [ "10.13.13.2/32" ];
        # }
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # State Persistence for Native Services (Bind-mounted from /persist)
  # ---------------------------------------------------------------------------
  fileSystems."/var/lib/AdGuardHome" = {
    device = "/persist/var/lib/AdGuardHome";
    options = [ "bind" "nofail" "x-systemd.device-timeout=30s" "x-systemd.requires=persist.mount" "x-systemd.after=persist.mount" ];
    noCheck = true;
    depends = [ "/persist" ];
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  # 1. Keepalived VRRP Backup Node (~4MB RAM, monitors port 443 for SWAG)
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
      priority = 100;
      unicastSrcIp = "192.168.1.12";
      unicastPeers = [ "192.168.1.11" ];
      virtualIps = [
        { addr = "192.168.1.9/24"; }
      ];
      trackScripts = [ "check_swag" ];
      extraConfig = ''
        include /persist/secrets/keepalived-auth.conf
        nopreempt
        use_vmac
        vmac_xmit_base
      '';
    };
  };


  # 3. AdGuard Home (~15MB RAM, secondary DNS resolver, web UI on port 3000)
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    port = 3000; # Web UI accessible at http://192.168.1.12:3000
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

  # ---------------------------------------------------------------------------
  # Remaining Docker Containers (SWAG, Portainer, Rclone)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # SWAG (Backup Reverse Proxy + Certbot)
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
        # Uses --network=host to bind directly to ports 80/443 without Docker bridge or NAT conflicts
        extraOptions = [
          "--network=host"
          "--read-only"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
          "--tmpfs=/config/log:size=16M"
        ];
      };

    };
  };

  # Native Restic backup of /persist to Dropbox via Rclone
  services.restic.backups.persist = {
    initialize = true;
    repository = "rclone:dropbox:backups/pi-secondary";
    rcloneConfigFile = "/persist/secrets/rclone.conf";
    passwordFile = "/persist/secrets/restic-password";
    paths = [
      "/persist"
    ];
    exclude = [
      "/persist/var/lib/docker"
    ];
    extraBackupArgs = [
      "--cache-dir=/tmp/restic-cache"
    ];
    timerConfig = {
      OnCalendar = "03:30"; # Staggered 30 mins after primary
      Persistent = true;
    };
    pruneOpts = [
      "--keep-daily 3"
      "--keep-weekly 2"
      "--keep-monthly 1"
    ];
  };

  system.stateVersion = "24.05";
}
