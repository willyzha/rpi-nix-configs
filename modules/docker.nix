{ config, lib, pkgs, ... }:

{
  # Docker container runtime configuration
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;

    # Point docker storage to the persistent partition to prevent
    # 1GB RAM exhaustion from container layers
    daemon.settings = {
      data-root = "/persist/var/lib/docker";
      storage-driver = "overlay2";
      log-driver = "json-file";
      log-opts = {
        max-size = "500k";
        max-file = "2";
      };
    };
  };

  # Make docker-compose CLI available
  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}
