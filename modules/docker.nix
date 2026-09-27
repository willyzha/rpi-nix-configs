{ config, lib, pkgs, ... }:

{
  # Docker container runtime configuration
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;

    # Point docker storage directly to the raw ext4 persistent partition (/persist-raw)
    # rather than the /persist OverlayFS, because Linux kernel overlay2 cannot run on an OverlayFS.
    # Steady-state containers run read-only with logs in RAM tmpfs to avoid SD wear.
    daemon.settings = {
      data-root = "/persist-raw/var/lib/docker";
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
