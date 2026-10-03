{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi4.nix
    ../../modules/docker.nix
    ../../modules/swag.nix
  ];

  networking = {
    hostName = "ott-pi-primary";
  };

  # Ottawa local timezone
  time.timeZone = "America/Toronto";

  # ---------------------------------------------------------------------------
  # Native NixOS Services
  # ---------------------------------------------------------------------------

  # 1. Eclipse Mosquitto MQTT Server (Native)
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        port = 1883;
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
      }
    ];
  };

  # 2. Tailscale (Native)
  services.tailscale = {
    enable = true;
  };

  # 3. WireGuard (Native)
  # Uses wg-quick to load the configuration directly from the persistent secret file
  networking.wg-quick.interfaces = {
    wg0 = {
      configFile = "/persist/secrets/wg0.conf";
    };
  };

  # ---------------------------------------------------------------------------
  # Docker Containers
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {

      # SWAG overrides for Ottawa DuckDNS
      swag.environment = {
        TZ = "America/Toronto";
        URL = "ottawahome.duckdns.org";
        VALIDATION = "duckdns";
        DNSPLUGIN = lib.mkForce "";
        PROPAGATION = lib.mkForce "";
      };

      # Home Assistant Matter Hub
      matter-hub = {
        image = "ghcr.io/riddix/home-assistant-matter-hub:latest";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/matter-hub.env" ]; # Store ACCESS_TOKEN here
        environment = {
          HAMH_HOME_ASSISTANT_URL = "https://hass-ottawa.wzhang.dev";
          HAMH_LOG_LEVEL = "info";
          HAMH_HTTP_PORT = "8482";
        };
        volumes = [
          "/persist/docker/ha-matter-hub:/data"
        ];
        extraOptions = [ "--network=host" ];
      };

      # Wyze Bridge
      wyze-bridge = {
        image = "idisposablegithub365/wyze-bridge";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/wyze-bridge.env" ]; # Store credentials/STREAM_AUTH here
        environment = {
          FILTER_NAMES = "Kitchen Cam";
          WB_AUTH = "False";
          MQTT_HOST = "127.0.0.1:1883"; # Pointed to local Mosquitto
        };
        # Ports are ignored by docker when network=host is used
        extraOptions = [ "--network=host" ];
      };

      # Room Assistant
      room-assistant = {
        image = "mkerix/room-assistant:2.20.0";
        autoStart = true;
        volumes = [
          "/var/run/dbus:/var/run/dbus"
          "/persist/docker/roomassistant/config:/room-assistant/config"
        ];
        extraOptions = [ 
          "--network=host"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
        ];
      };

    };
  };

  system.stateVersion = "24.05";
}
