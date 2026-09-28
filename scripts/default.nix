{ config, lib, pkgs, ... }:

{
  # Aggregate all modular maintenance and setup scripts into system packages
  environment.systemPackages = [
    (import ./rpi-set-password.nix { inherit pkgs; })
    (import ./rpi-set-nut-password.nix { inherit pkgs; })
    (import ./rpi-set-keepalived-auth.nix { inherit pkgs; })
    (import ./rpi-set-restic-password.nix { inherit pkgs; })
    (import ./rpi-init-secrets.nix { inherit pkgs; })
    (import ./rpi-set-swag.nix { inherit pkgs; })
    (import ./rpi-persist-save.nix { inherit pkgs; })
    (import ./rpi-rebuild.nix { inherit pkgs; })
    (import ./rpi-check-update.nix { inherit pkgs; })
    (import ./rpi-vrrp-status.nix { inherit pkgs; })
    (import ./rpi-services-status.nix { inherit pkgs; })
  ];
}
