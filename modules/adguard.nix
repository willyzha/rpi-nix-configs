{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # AdGuard Home DNS Resolver & Ad Blocker (~15MB RAM)
  # Shared configuration for high-availability cluster nodes
  # ---------------------------------------------------------------------------
  services.adguardhome = {
    enable = lib.mkDefault true;
    mutableSettings = false; # Strict GitOps: Web UI changes are wiped on service restart/rebuild
    port = lib.mkDefault 3000; # Web UI accessible at http://<node-ip>:3000

    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        # Security: DNS-over-HTTPS (DoH) upstreams (Quad9 + Cloudflare Malware blocking)
        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://security.cloudflare-dns.com/dns-query"
        ];

        # Bootstrap DNS to resolve DoH provider hostnames
        bootstrap_dns = [
          "9.9.9.9"
          "1.1.1.1"
        ];

        # Performance: Query all upstreams simultaneously and return the fastest response
        upstream_mode = "parallel";

        # Performance: DNS Caching optimization
        cache_size = 4194304; # 4MB cache
        cache_ttl_min = 3600; # 1 hour minimum TTL
        cache_ttl_max = 86400; # 1 day maximum TTL

        # Disable rate limiting for local network devices
        ratelimit = 0;
      };

      querylog = {
        enabled = true;
        interval = "24h";
        size_memory = 1000;
      };

      filters = [
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
          name = "AdGuard DNS filter";
          id = 1;
        }
        {
          enabled = true;
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
          name = "AdAway Default Blocklist";
          id = 2;
        }
        {
          enabled = true;
          url = "https://big.oisd.nl";
          name = "OISD Big (Zero False Positives)";
          id = 3;
        }
      ];
    };
  };
}
