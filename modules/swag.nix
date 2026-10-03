{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # SWAG (Secure Web Application Gateway) Reverse Proxy & Let's Encrypt Certbot
  # Runs containerized via Docker with zero SD card wear (read-only root + RAM tmpfs)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers.swag = {
      image = "ghcr.io/linuxserver/swag:latest";
      autoStart = true;
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = lib.mkDefault "America/Los_Angeles";
        SUBDOMAINS = lib.mkDefault "wildcard";
        VALIDATION = lib.mkDefault "dns";
        DNSPLUGIN = lib.mkDefault "cloudflare";
        PROPAGATION = lib.mkDefault "30";
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
      # Uses --network=host to bind directly to ports 80/443 without Docker bridge or NAT conflicts with Tailscale/VRRP
      extraOptions = [
        "--network=host"
        "--read-only"
        "--tmpfs=/tmp:exec"
        "--tmpfs=/run:exec"
        "--tmpfs=/config/log:size=16M"
      ];
    };
  };
}
