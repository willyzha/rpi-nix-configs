{ config, lib, pkgs, ... }:

{
  imports = [
    ../scripts
    ./mqtt-monitor.nix
  ];
  # Time zone matching your existing setup
  time.timeZone = "America/Los_Angeles";

  # Localization
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable zram compressed swap to prevent OOM on 1GB RAM Pi 3 (compressed RAM, zero SD wear)
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # Nix configuration
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = false; # Avoid heavy disk writes on SD
      warn-dirty = false;
      trusted-users = [ "root" "@wheel" ];
    };
    gc = {
      automatic = false;
    };
  };

  # Expose configuration revision directly in /run/current-system/configuration-revision
  system.extraSystemBuilderCmds = lib.optionalString (config.system.configurationRevision != null) ''
    echo -n "${config.system.configurationRevision}" > $out/configuration-revision
  '';


  # Networking
  networking = {
    usePredictableInterfaceNames = lib.mkDefault false; # Keep eth0 interface name for SMSC9514 USB-Ethernet
    useDHCP = lib.mkDefault true; # Auto-detect IP, router gateway, and DNS on any network
    firewall.enable = false; # Disable internal firewall by default (handled by container/services)
    nameservers = [ "192.168.1.11" "1.1.1.1" "9.9.9.9" ];
  };

  # Kernel sysctl tuning for Keepalived VMAC (Virtual MAC) and seamless failover
  boot.kernel.sysctl = {
    # IP forwarding and routing marks for containers, WireGuard, and Tailscale
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.src_valid_mark" = 1;

    # Disable strict reverse path filtering so packets routed to VMAC (vrrp.51) aren't dropped
    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;
    "net.ipv4.conf.eth0.rp_filter" = 0;

    # Allow services (AdGuard, Docker, Glances) to bind/listen seamlessly during failover
    "net.ipv4.ip_nonlocal_bind" = 1;

    # Ensure ARP queries for the VIP answer strictly with the Virtual MAC address
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
  };

  # Zero-config local network discovery (e.g., ssh pi@pi-primary.local)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true;
    };
  };

  # Allow user passwords to be modified via passwd (survives reboots on ext4 root)
  users.mutableUsers = true;

  # Default user 'pi'
  users.users.pi = {
    isNormalUser = true;
    home = "/home/pi";
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFz7zweHTuKuHEQv7xtzH8I3T1Ch+Mafg+S4a00hcniR willyzha@willy-dev"
    ];
  };

  # Root SSH key (for remote nixos-rebuild deployments)
  users.users.root.openssh.authorizedKeys.keys = config.users.users.pi.openssh.authorizedKeys.keys;

  # Passwordless sudo for wheel group
  security.sudo = {
    wheelNeedsPassword = false;
  };

  # Common utility packages
  environment.systemPackages = with pkgs; [
    vim
    nano
    git
    curl
    wget
    htop
    iotop
    tmux
    rsync
    ncdu
    pciutils
    usbutils
    jq
    restic
    rclone
    wireguard-tools
    psmisc
    lsof
  ];

  # Allow unfree packages if needed
  nixpkgs.config.allowUnfree = true;
}
