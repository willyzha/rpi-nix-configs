{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.espresense-tracker;
  
  # Python environment with paho-mqtt
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    paho-mqtt
  ]);

  # The Python script
  trackerScript = pkgs.writeScript "espresense-tracker.py" (builtins.readFile ../scripts/espresense-simple-tracker.py);

in {
  options.services.espresense-tracker = {
    enable = mkEnableOption "Simple ESPresense MQTT Tracker for Home Assistant";

    mqttHost = mkOption {
      type = types.str;
      default = "localhost";
      description = "MQTT broker hostname or IP address";
    };

    mqttPort = mkOption {
      type = types.port;
      default = 1883;
      description = "MQTT broker port";
    };

    mqttUser = mkOption {
      type = types.str;
      default = "";
      description = "MQTT username (optional)";
    };

    mqttPasswordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing MQTT password";
    };

    devices = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "apple:1234:5678" "tile:abcd" ];
      description = "List of device IDs to track. Use ['*'] to track all devices.";
    };

    nodeTimeout = mkOption {
      type = types.int;
      default = 30;
      description = "Time in seconds before a node's reading is considered stale (equivalent to timeout in espresense-companion)";
    };

    awayTimeout = mkOption {
      type = types.int;
      default = 120;
      description = "Time in seconds before marking a device as not_home after all nodes are stale (equivalent to away_timeout)";
    };

    maxDistance = mkOption {
      type = types.str; # str to allow floats like "15.0"
      default = "15.0";
      description = "Maximum distance in meters to consider a device home";
    };
    envFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to an environment file to load dynamically (e.g. /persist/secrets/espresense.env)";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.espresense-tracker = {
      description = "ESPresense Simple MQTT Tracker";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        MQTT_HOST = cfg.mqttHost;
        MQTT_PORT = toString cfg.mqttPort;
        MQTT_USER = cfg.mqttUser;
        NODE_TIMEOUT = toString cfg.nodeTimeout;
        AWAY_TIMEOUT = toString cfg.awayTimeout;
        MAX_DISTANCE = toString cfg.maxDistance;
      } // optionalAttrs (length cfg.devices > 0) {
        DEVICES = concatStringsSep "," cfg.devices;
      };

      script = ''
        if [ -n "${if cfg.mqttPasswordFile != null then cfg.mqttPasswordFile else ""}" ]; then
          export MQTT_PASSWORD=$(cat "${if cfg.mqttPasswordFile != null then cfg.mqttPasswordFile else ""}")
        fi
        
        exec ${pythonEnv}/bin/python ${trackerScript}
      '';

      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
        DynamicUser = true;
      } // (optionalAttrs (cfg.envFile != null) {
        EnvironmentFile = [ cfg.envFile ];
      });
    };
  };
}
