{ config, lib, pkgs, ... }:

{
  # Time zone matching your existing setup
  time.timeZone = "America/Los_Angeles";

  # Localization
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable zram compressed swap to prevent OOM on 1GB RAM Pi 3
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Nix configuration
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = false; # Avoid heavy disk writes on SD
      warn-dirty = false;
    };
    gc = {
      automatic = false; # Manual GC preferred to avoid unexpected SD writes
    };
  };

  # Networking
  networking = {
    usePredictableInterfaceNames = lib.mkDefault false; # Keep eth0 interface name for SMSC9514 USB-Ethernet
    useDHCP = lib.mkDefault true; # Auto-detect IP, router gateway, and DNS on any network
    firewall.enable = false; # Disable internal firewall by default (handled by container/services)
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
