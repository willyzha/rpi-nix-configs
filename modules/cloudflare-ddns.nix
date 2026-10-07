{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.cloudflare-ddns;
in
{
  options.services.cloudflare-ddns = {
    enable = mkEnableOption "Cloudflare Dynamic DNS updater with zero SD card wear";

    domains = mkOption {
      type = types.listOf types.str;
      default = [ "example.com" "*.example.com" ];
      description = "List of domain names to update with the public WAN IP.";
    };

    apiTokenFile = mkOption {
      type = types.str;
      default = "/persist/secrets/cloudflare.env";
      description = "Path to environment file containing CLOUDFLARE_API_TOKEN=<token>.";
    };

    proxied = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the records are receiving Cloudflare proxying (CDN/WAF).";
    };

    frequency = mkOption {
      type = types.nullOr types.str;
      default = "*:0/5";
      description = "Systemd calendar expression for how often to check WAN IP (default: every 5 minutes).";
    };
  };

  config = mkIf cfg.enable {
    # NixOS native cloudflare-dyndns client
    services.cloudflare-dyndns = {
      enable = true;
      apiTokenFile = cfg.apiTokenFile;
      domains = cfg.domains;
      proxied = cfg.proxied;
      ipv4 = true;
      ipv6 = false;
    };

    # Volatile cache in RAM: completely prevents SD card writes when IP has not changed
    fileSystems."/var/lib/cloudflare-dyndns" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "nosuid" "nodev" "noatime" "mode=0700" "size=2M" ];
    };

    # Ensure mount point directory exists on read-only root before mounting
    system.activationScripts.ensureCloudflareDdnsMountPoint = lib.stringAfter [ ] ''
      ${pkgs.util-linux}/bin/mount -o remount,rw / || true
      mkdir -p /var/lib/cloudflare-dyndns
    '';

    # Service overrides for zero-wear read-only root & graceful secret handling
    systemd.services.cloudflare-dyndns = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      startAt = mkIf (cfg.frequency != null) (mkForce cfg.frequency);
      unitConfig = {
        # Only run if secret token exists; avoids failed units on fresh install before secrets are set
        ConditionPathExists = cfg.apiTokenFile;
      };
      serviceConfig = {
        DynamicUser = mkForce false;
        User = "root";
      };
    };

    # Stagger timer by up to 30s so primary and secondary don't hit Cloudflare API at the exact same second
    systemd.timers.cloudflare-dyndns.timerConfig = mkIf (cfg.frequency != null) {
      RandomizedDelaySec = "30s";
    };
  };
}
