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
    interfaces.eth0 = {
      ipv4.addresses = [{
        address = "192.168.1.12";
        prefixLength = 24;
      }];
    };
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.11" "1.1.1.1" ];

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

  # Kernel IP forwarding and routing marks for WireGuard
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.src_valid_mark" = 1;
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  # 1. Keepalived VRRP Backup Node (~4MB RAM, monitors port 443 for SWAG)
  services.keepalived = {
    enable = true;
    extraGlobalDefs = ''
      vrrp_garp_master_repeat 5
      vrrp_garp_master_refresh 60
    '';
    vrrpScripts.check_swag = {
      script = "${pkgs.iproute2}/bin/ss -tlpn | grep -q :443";
      interval = 2;
      weight = -20;
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
      '';
    };
  };

  # 2. Glances System Monitor (~45MB RAM, runs natively via systemd)
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
  # Remaining Docker Containers (SWAG, Portainer, Rclone)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # SWAG (Backup Reverse Proxy + Certbot)
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
        # Prevent runtime SD card writes: container root is read-only, logs & runtime in RAM
        extraOptions = [
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
