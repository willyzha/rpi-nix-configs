{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
    ../../modules/adguard.nix
    ../../modules/swag.nix
  ];

  networking = {
    hostName = "kir-pi-secondary";

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
  fileSystems."/var/lib/tailscale" = {
    device = "/persist/var/lib/tailscale";
    options = [ "bind" "nofail" "x-systemd.device-timeout=30s" "x-systemd.requires=persist.mount" "x-systemd.after=persist.mount" ];
    noCheck = true;
    depends = [ "/persist" ];
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server"; # Allow exit node/subnet router functionality
  };

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
      "--no-cache"
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

  systemd.services."restic-backups-persist".serviceConfig.ExecStopPost = [
    "-/bin/sh -c 'if [ \"$SERVICE_RESULT\" = \"success\" ]; then mkdir -p /persist/var/cache/restic && date -u +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success; fi'"
  ];

  system.stateVersion = "24.05";
}
