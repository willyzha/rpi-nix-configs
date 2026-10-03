{ config, lib, pkgs, ... }:

{
  imports = [
    ../scripts
    ./mqtt-monitor.nix
    ./restic.nix
  ];
  # Time zone matching your existing setup (defaults to America/Los_Angeles, overrideable per host)
  time.timeZone = lib.mkDefault "America/Los_Angeles";

  # Localization
  i18n.defaultLocale = "en_US.UTF-8";

  # Hardware clock fallback: Pi 3 has no RTC. Use raw IP time servers so clock syncs immediately without DNS
  services.timesyncd = {
    enable = true;
    servers = [
      "216.239.35.0" # time.google.com IP fallback
      "216.239.35.4" # time.google.com IP fallback
      "1.1.1.1"      # Cloudflare NTP IP fallback
      "time.google.com"
      "pool.ntp.org"
    ];
  };

  # Enable zram compressed swap to prevent OOM on 1GB RAM Pi 3 (compressed RAM, zero SD wear)
  # Enable EarlyOOM to prevent RCU kernel stall during heavy memory pressure
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5; # kill when < 5% RAM
    freeSwapThreshold = 10; # kill when < 10% swap
    extraArgs = [
      "--avoid" "^(sshd|tailscaled)$" # Prioritize keeping remote access alive
      "--prefer" "^(restic|docker)$" # Aggressively kill backup/docker if OOM
    ];
  };


  # Hardware Watchdog & Auto-Reboot on Kernel Panic
  # BCM2835 WDT has a strict 15-second maximum timeout.
  systemd.watchdog.runtimeTime = "14s"; # systemd will ping the WDT every 7s
  systemd.watchdog.rebootTime = "14s";
  systemd.watchdog.kexecTime = "14s";

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
    useDHCP = lib.mkDefault false; # Avoid acquiring DHCP leases on virtual interfaces (vrrp.51, wg0, docker0)
    interfaces.eth0.useDHCP = lib.mkDefault true; # Auto-detect IP on physical eth0
    firewall.enable = false; # Disable internal firewall by default (handled by container/services)
    nameservers = lib.mkDefault [ "1.1.1.1" "9.9.9.9" ];
  };

  # Kernel sysctl tuning for Keepalived VMAC (Virtual MAC) and seamless failover
  boot.kernel.sysctl = {
    # IP forwarding and routing marks for containers, WireGuard, and Tailscale
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.src_valid_mark" = 1;

    # Auto-reboot safely on kernel panics (e.g. RCU starvation or soft lockups) instead of freezing forever
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
    "kernel.softlockup_panic" = 1;
    "kernel.hung_task_panic" = 1;
    "kernel.hung_task_timeout_secs" = 120;
    "vm.panic_on_oom" = 0; # Let earlyoom handle OOM natively, but panic if kernel OOM fails


    # Disable strict reverse path filtering so packets routed to VMAC (vrrp.51) aren't dropped
    "net.ipv4.conf.all.rp_filter" = 0;
    "net.ipv4.conf.default.rp_filter" = 0;
    "net.ipv4.conf.eth0.rp_filter" = 0;

    # Allow services (AdGuard, Docker, reverse proxy) to bind/listen seamlessly during failover
    "net.ipv4.ip_nonlocal_bind" = 1;

    # Ensure ARP queries for the VIP answer strictly with the Virtual MAC address
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
  };

  # Zero-config local network discovery (e.g., ssh pi@pi-primary.local)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    allowInterfaces = [ "eth0" ]; # Only publish real physical ethernet IP, never virtual/vrrp interfaces
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
