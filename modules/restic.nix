{ config, lib, pkgs, ... }:

let
  hostName = config.networking.hostName;
  calendarTime =
    if hostName == "kir-pi-secondary" then "04:30"
    else "03:00";

  postBackupScript = pkgs.writeShellScript "restic-post-backup" ''
    if [ "$SERVICE_RESULT" = "success" ]; then
      ${pkgs.coreutils}/bin/mkdir -p /persist/var/cache/restic
      ${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ > /persist/var/cache/restic/last_success
      if command -v rpi-persist-save >/dev/null 2>&1; then
        rpi-persist-save var/cache/restic || true
      fi
    fi
  '';
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
      "/persist/var/cache"
      "/persist/var/lib/AdGuardHome/data/querylog.json*"
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

  # Resource throttling & safeguards: prevent Restic from pinning CPU/RAM and starving the 14s watchdog
  systemd.services."restic-backups-persist" = {
    serviceConfig = {
      Nice = 19;
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      MemoryMax = "250M";
      MemoryHigh = "180M";
      ExecStopPost = [
        "-${postBackupScript}"
      ];
    };
    environment = {
      GOMAXPROCS = "1";
      GOGC = "20";
    };
  };
}
