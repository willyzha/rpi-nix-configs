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
    firewall.enable = false; # Disable internal firewall by default (handled by container/services)
  };

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true;
    };
  };

  # Default user 'pi'
  users.users.pi = {
    isNormalUser = true;
    home = "/home/pi";
    extraGroups = [ "wheel" "docker" ];
    # Read password hash from persistent storage (untracked by git)
    # Generate on target: mkpasswd -m sha-512 "your-password" > /persist/secrets/pi-password-hash
    # chmod 600 /persist/secrets/pi-password-hash
    hashedPasswordFile = lib.mkIf (builtins.pathExists "/persist/secrets/pi-password-hash") "/persist/secrets/pi-password-hash";
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
  ];

  # Allow unfree packages if needed
  nixpkgs.config.allowUnfree = true;
}
