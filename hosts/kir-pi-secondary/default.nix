{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
    ../../modules/adguard.nix
    ../../modules/swag.nix
    ../../modules/cloudflare-ddns.nix
  ];

  networking = {
    hostName = "kir-pi-secondary";
    firewall.checkReversePath = "loose"; # Required for Tailscale subnet router/exit node
    nameservers = [ "127.0.0.1" "192.168.1.9" "1.1.1.1" ];

    # In-Kernel WireGuard VPN server (0 MB daemon RAM, runs directly in Linux kernel)
    wireguard.interfaces.wg0 = {
      ips = [ "10.13.13.1/24" ];
      listenPort = 51821;
      # Load private key from persistent storage (untracked by git):
      # Generate with: wg genkey > /persist/secrets/wireguard/private.key
      privateKeyFile = "/persist/secrets/wireguard/private.key";
      peers = [
        # Static peers can be defined here, or generated dynamically via 'sudo rpi-wg-client'
      ];

      # Automatically restore all client peers saved in /persist/secrets/wireguard/peers on boot
      postSetup = ''
        if [ -d /persist/secrets/wireguard/peers ]; then
          for peer_file in /persist/secrets/wireguard/peers/*.conf; do
            if [ -f "$peer_file" ]; then
              ${pkgs.wireguard-tools}/bin/wg addconf wg0 "$peer_file" 2>/dev/null || true
            fi
          done
        fi
      '';
    };

    # NAT Masquerade so WireGuard clients can reach the LAN and Internet
    nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = [ "wg0" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both"; # Allow exit node/subnet router functionality
    extraUpFlags = [
      "--advertise-routes=192.168.1.0/24"
      "--advertise-exit-node"
      "--stateful-filtering=false"
      "--accept-dns=false"
    ];
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
        { addr = "192.168.1.9/32"; }
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

  # 2. Cloudflare Dynamic DNS Updater (Secondary Node - Redundant HA)
  services.cloudflare-ddns.enable = true;

  system.stateVersion = "24.05";
}
