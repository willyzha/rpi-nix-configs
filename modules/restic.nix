{ config, lib, pkgs, ... }:

let
  hostName = config.networking.hostName;
  calendarTime =
    if hostName == "kir-pi-secondary" then "03:30"
    else "03:00";
in
{
  # Native Restic backup of /persist to Dropbox via Rclone
  services.restic.backups.persist = {
    initialize = true;
    repository = lib.mkDefault "rclone:dropbox:backups/${hostName}";
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
      OnCalendar = lib.mkDefault calendarTime;
      Persistent = true;
    };
    pruneOpts = [
      "--keep-daily 3"
      "--keep-weekly 2"
      "--keep-monthly 1"
    ];
  };

  systemd.services."restic-backups-persist".serviceConfig.ExecStopPost = [
    "-${pkgs.bash}/bin/bash -c 'if [ \"$SERVICE_RESULT\" = \"success\" ]; then ${pkgs.coreutils}/bin/mkdir -p /persist/var/cache/restic && ${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success; fi'"
  ];
}
