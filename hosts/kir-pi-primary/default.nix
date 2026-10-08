{ config, lib, pkgs, ... }:

{
  imports = [
    ../../modules/common.nix
    ../../modules/sd-protection.nix
    ../../modules/hardware-rpi3.nix
    ../../modules/docker.nix
    ../../modules/adguard.nix
    ../../modules/swag.nix
    ../../modules/espresense-tracker.nix
    ../../modules/cloudflare-ddns.nix
  ];

  networking = {
    hostName = "kir-pi-primary";
    firewall.checkReversePath = "loose"; # Required for Tailscale subnet router/exit node
    nameservers = [ "127.0.0.1" "192.168.1.9" "1.1.1.1" ];
  };

  # ---------------------------------------------------------------------------
  # Native NixOS Services (Substantially saves RAM on 1 GB Pi 3B)
  # ---------------------------------------------------------------------------

  # 1. Tailscale Subnet Router & Exit Node (~20MB RAM, no container overhead)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [
      "--advertise-exit-node"
      "--stateful-filtering=false"
      "--accept-dns=false"
    ];
  };

  # 2. Keepalived VRRP Master (~4MB RAM, monitors port 443 for SWAG)
  services.keepalived = {
    enable = true;
    extraGlobalDefs = ''
      enable_script_security
      vrrp_garp_master_repeat 5
      vrrp_garp_master_refresh 60
    '';
    vrrpScripts.check_swag = {
      script = "${pkgs.iproute2}/bin/ss -tlpn | ${pkgs.gnugrep}/bin/grep -q :443";
      interval = 2;
      weight = -20;
      user = "root";
    };
    vrrpInstances.VI_1 = {
      interface = "eth0";
      state = "BACKUP";
      virtualRouterId = 51;
      priority = 105;
      unicastSrcIp = "192.168.1.11";
      unicastPeers = [ "192.168.1.12" ];
      virtualIps = [
        { addr = "192.168.1.9/32"; }
      ];
      trackScripts = [ "check_swag" ];
      # Auth config loaded from persistent untracked secret file if present
      extraConfig = ''
        include /persist/secrets/keepalived-auth.conf
        nopreempt
        use_vmac
        vmac_xmit_base
      '';
    };
  };

  # 4. Network UPS Tools (NUT) Server (~4MB RAM, CyberPower PR1500LCDRT2U)
  power.ups = {
    enable = true;
    mode = "netserver";
    upsmon.enable = false;
    ups."cyberpower" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower PR1500LCDRT2U";
      directives = [
        "vendorid = 0764"
        "productid = 0601"
        "pollonly"
      ];
    };
    upsd = {
      enable = true;
      listen = [
        { address = "0.0.0.0"; port = 3493; }
      ];
    };
    users.monuser = {
      passwordFile = "/persist/secrets/nut-monuser-password";
      upsmon = "master";
    };
  };

  # 5. Cloudflare Dynamic DNS Updater (Primary Node)
  services.cloudflare-ddns.enable = true;

  # ---------------------------------------------------------------------------
  # Remaining Docker Containers (Kept in Docker per configuration)
  # ---------------------------------------------------------------------------
  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      # UPS Wake-on-LAN client (connects to native NUT server on localhost:3493)
      upswake = {
        image = "thedarthmole/upswake:latest";
        autoStart = true;
        extraOptions = [
          "--network=host"
          "--read-only"
        ];
        volumes = [
          "/persist/docker/nut_server/upswake/upswake-config.yaml:/config.yaml:ro"
          "/persist/docker/nut_server/upswake/upswake-rules:/rules/:ro"
        ];
        cmd = [ "serve" ];
      };

      # Home Assistant Matter Hub (Matter bridge to Apple Home, Google Home, Alexa)
      matter-hub = {
        image = "ghcr.io/riddix/home-assistant-matter-hub:latest";
        autoStart = true;
        environmentFiles = [ "/persist/secrets/matter-hub.env" ];
        environment = {
          HAMH_LOG_LEVEL = "info";
          HAMH_HTTP_PORT = "8482";
        };
        volumes = [
          "/persist/docker/ha-matter-hub:/data"
        ];
        extraOptions = [ "--network=host" ];
      };
    };
  };

  # ESPresense Simple Tracker
  services.espresense-tracker = {
    enable = true;
    mqttHost = "192.168.1.10";
    envFile = "/persist/secrets/espresense-tracker.env";
  };

  system.stateVersion = "24.05";
}
