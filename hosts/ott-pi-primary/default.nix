{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi4.nix
    ../../modules/docker.nix
  ];

  networking = {
    hostName = "ott-pi-primary";
    firewall.checkReversePath = "loose";
  };

  # Ottawa local timezone
  time.timeZone = "America/Toronto";

  # ---------------------------------------------------------------------------
  # Bluetooth Hardware Support (Room-Assistant)
  # ---------------------------------------------------------------------------
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Volatile Bluetooth state in RAM: allows bluetoothd to manage state on read-only root
  fileSystems."/var/lib/bluetooth" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "noatime" "mode=0700" ];
  };


  # 1. Eclipse Mosquitto MQTT Server (Native)
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        port = 1883;
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
        acl = [
          "topic readwrite #"
          "pattern readwrite #"
        ];
      }
    ];
  };

  # Volatile Mosquitto state in RAM: allows mosquitto to save in-memory database on read-only root
  fileSystems."/var/lib/mosquitto" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "noatime" "mode=0700" "uid=mosquitto" "gid=mosquitto" "size=16M" ];
  };

  # 2. Tailscale (Native)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [
      "--advertise-routes=192.168.2.0/24"
      "--advertise-exit-node"
      "--stateful-filtering=false"
      "--accept-dns=false"
    ];
  };

  # 3. WireGuard (Native)
  # Uses wg-quick to load the configuration directly from the persistent secret file
  networking.wg-quick.interfaces = {
    wg0 = {
      configFile = "/persist/secrets/wg0.conf";
    };
  };

  # Provide wireguard-wg0.service alias for seamless cross-node systemctl compatibility
  systemd.services.wg-quick-wg0.aliases = [ "wireguard-wg0.service" ];

  # ---------------------------------------------------------------------------
  # Docker Containers
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {


      # Home Assistant Matter Hub
      matter-hub = {
        image = "ghcr.io/riddix/home-assistant-matter-hub:latest";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/matter-hub.env" ]; # Store HAMH_HOME_ASSISTANT_URL and ACCESS_TOKEN here
        environment = {
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
          MQTT_HOST = "127.0.0.1"; # Pointed to local Mosquitto
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
          "--cap-add=NET_ADMIN"
          "--cap-add=NET_RAW"
          "--tmpfs=/tmp:exec"
          "--tmpfs=/run:exec"
        ];
      };

    };
  };

  system.stateVersion = "24.05";
}
