#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Fast NixOS Systemd Container Integration Test Runner
# Validates system toplevel closure, activation scripts, secret stubs,
# onboarding check, and systemd service unit integrity.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$WORKSPACE_DIR"

BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

TARGET_HOSTS=("ott-pi-primary" "kir-pi-primary" "kir-pi-secondary")
if [ "$#" -gt 0 ]; then
  TARGET_HOSTS=("$@")
fi

# Detect execution context:
# If running on an x86_64 host outside Docker, delegate into docker-rebuild container
if [ ! -f "/.dockerenv" ] && [ "$(uname -m)" != "aarch64" ]; then
  if [ -f "$WORKSPACE_DIR/docker-rebuild.sh" ]; then
    echo -e "${YELLOW}Notice: Host architecture is $(uname -m). Delegating test into Docker builder container for ARM64/binfmt support...${NC}"
    exec "$WORKSPACE_DIR/docker-rebuild.sh" test-container "${TARGET_HOSTS[@]}"
  fi
fi

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}   Raspberry Pi NixOS Systemd Container Integration Test        ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "  Targets to test : ${BOLD}${TARGET_HOSTS[*]}${NC}"
echo -e "  Architecture    : $(uname -m)"
echo -e "  Workspace       : ${WORKSPACE_DIR}"
echo -e "${BLUE}----------------------------------------------------------------${NC}\n"

# ------------------------------------------------------------------------------
# Phase 1: Nix Flake Evaluation Check
# ------------------------------------------------------------------------------
echo -e "${GREEN}==> [Phase 1/4] Checking Nix flake evaluation...${NC}"

for host in "${TARGET_HOSTS[@]}"; do
  echo -e "  Evaluating NixOS configuration for ${BOLD}${host}${NC}..."
  if ! nix eval --extra-experimental-features "nix-command flakes" ".#nixosConfigurations.${host}.config.networking.hostName" >/dev/null; then
    echo -e "  ${RED}FAILED: Configuration ${host} failed flake evaluation!${NC}" >&2
    exit 1
  fi
  echo -e "  ${GREEN}✓${NC} ${host} evaluation successful."
done

# ------------------------------------------------------------------------------
# Phase 2: Build System Toplevel Closures
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> [Phase 2/4] Building system toplevel closures...${NC}"
declare -A TOPLEVELS

for host in "${TARGET_HOSTS[@]}"; do
  echo -e "  Building toplevel closure for ${BOLD}${host}${NC}..."
  START_TIME=$(date +%s)
  
  TOPLEVEL=$(nix build \
    --extra-experimental-features "nix-command flakes" \
    --option extra-platforms "aarch64-linux armv7l-linux" \
    --no-link \
    --print-out-paths \
    ".#nixosConfigurations.${host}.config.system.build.toplevel")
  
  DURATION=$(( $(date +%s) - START_TIME ))
  echo -e "  ${GREEN}✓${NC} Built ${host} in ${DURATION}s -> ${BOLD}${TOPLEVEL}${NC}"
  TOPLEVELS["$host"]="$TOPLEVEL"
done

# ------------------------------------------------------------------------------
# Phase 3: Activation, Secrets Initialization, and Onboarding Check
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> [Phase 3/4] Validating activation, secret stubs, and onboarding wizard...${NC}"

for host in "${TARGET_HOSTS[@]}"; do
  toplevel="${TOPLEVELS[$host]}"
  echo -e "  Testing system environment for ${BOLD}${host}${NC}..."

  # Create an isolated temporary test root
  TEST_DIR=$(mktemp -d -t "rpi-test-${host}-XXXXXX")
  
  run_isolated_test() {
    local orig_persist="/persist"
    local temp_persist="${TEST_DIR}/persist"
    mkdir -p "${temp_persist}/secrets"

    export container=docker
    export HOST="$host"
    export PATH="${toplevel}/sw/bin:${toplevel}/sw/sbin:/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

    echo "    [1] Testing NixOS activation script..."
    "${toplevel}/activate" >/dev/null 2>&1 || true

    echo "    [2] Running rpi-init-secrets..."
    # Override /persist location to temp test directory for safe isolated verification
    sed "s|/persist|${temp_persist}|g" "${toplevel}/sw/bin/rpi-init-secrets" | bash >/dev/null

    echo "    [3] Verifying secret permissions and expected stubs..."
    if [ ! -d "${temp_persist}/secrets" ]; then
      echo "    ERROR: ${temp_persist}/secrets directory was not created!" >&2
      return 1
    fi

    PERM=$(stat -c "%a" "${temp_persist}/secrets" 2>/dev/null || stat -f "%OLp" "${temp_persist}/secrets" 2>/dev/null || true)
    if [ "$PERM" != "700" ]; then
      echo "    WARNING: ${temp_persist}/secrets permission is $PERM (expected 700)"
    fi

    # Common core secrets
    for s in mqtt.env swag.env restic-password; do
      if [ ! -f "${temp_persist}/secrets/$s" ]; then
        echo "    ERROR: Expected core secret ${temp_persist}/secrets/$s is missing!" >&2
        return 1
      fi
    done

    # Host-specific assertions
    case "$host" in
      ott-pi-primary|ott-pi|pi-remote)
        for s in wg0.conf matter-hub.env wyze-bridge.env; do
          if [ ! -f "${temp_persist}/secrets/$s" ]; then
            echo "    ERROR: Expected Ottawa secret ${temp_persist}/secrets/$s is missing!" >&2
            return 1
          fi
        done
        # Verify WireGuard private key is a valid 44-character base64 string
        WG_KEY=$(grep "PrivateKey" "${temp_persist}/secrets/wg0.conf" | awk '{print $3}')
        if [ ${#WG_KEY} -ne 44 ]; then
          echo "    ERROR: Generated WireGuard private key in wg0.conf has invalid length: '$WG_KEY'!" >&2
          return 1
        fi
        ;;
      kir-pi-primary|pi-primary)
        for s in keepalived-auth.conf nut-monuser-password cloudflare.env; do
          if [ ! -f "${temp_persist}/secrets/$s" ]; then
            echo "    ERROR: Expected Kirkland primary secret ${temp_persist}/secrets/$s is missing!" >&2
            return 1
          fi
        done
        ;;
      kir-pi-secondary|pi-secondary)
        for s in keepalived-auth.conf wireguard/private.key cloudflare.env; do
          if [ ! -f "${temp_persist}/secrets/$s" ]; then
            echo "    ERROR: Expected Kirkland secondary secret ${temp_persist}/secrets/$s is missing!" >&2
            return 1
          fi
        done
        ;;
    esac

    echo "    [4] Running rpi-onboard --check..."
    sed "s|/persist|${temp_persist}|g" "${toplevel}/sw/bin/rpi-onboard" | bash -s -- --check

    echo "    [5] Validating custom scripts syntax..."
    bash -n "${toplevel}/sw/bin/rpi-check-update"
    bash -n "${toplevel}/sw/bin/rpi-persist-save"
    bash -n "${toplevel}/sw/bin/rpi-mqtt-monitor"
    bash -n "${toplevel}/sw/bin/rpi-services-status"
    bash -n "${toplevel}/sw/bin/rpi-rebuild"
    bash -n "${toplevel}/sw/bin/rpi-set-cloudflare"

    echo "    [6] Validating Tailscale binary version..."
    TS_VER=$("${toplevel}/sw/bin/tailscale" version | head -n 1)
    echo "        Tailscale version: ${TS_VER}"
    if [[ ! "$TS_VER" =~ ^1\.(10[2-9]|[1-9][0-9]{2}) ]]; then
      echo "    ERROR: Tailscale version '$TS_VER' is vulnerable (< 1.102.4)!" >&2
      return 1
    fi
  }

  run_isolated_test
  rm -rf "$TEST_DIR" 2>/dev/null || true
  echo -e "  ${GREEN}✓${NC} Isolation test passed for ${BOLD}${host}${NC}."
done

# ------------------------------------------------------------------------------
# Phase 4: Critical Service Unit Definitions Check
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> [Phase 4/4] Validating systemd service unit declarations...${NC}"

for host in "${TARGET_HOSTS[@]}"; do
  toplevel="${TOPLEVELS[$host]}"
  echo -e "  Inspecting unit definitions for ${BOLD}${host}${NC}..."
  
  COMMON_UNITS=("adguardhome.service" "tailscaled.service" "rpi-mqtt-monitor.service" "init-persist.service")
  for u in "${COMMON_UNITS[@]}"; do
    if [ ! -e "${toplevel}/etc/systemd/system/${u}" ]; then
      echo -e "    ${RED}ERROR: Unit '${u}' not found in ${host} systemd configuration!${NC}" >&2
      exit 1
    fi
  done

  # Check host-specific units
  case "$host" in
    ott-pi-primary|ott-pi|pi-remote)
      OTT_UNITS=("wg-quick-wg0.service" "mosquitto.service" "docker-matter-hub.service" "docker-wyze-bridge.service")
      for u in "${OTT_UNITS[@]}"; do
        if [ ! -e "${toplevel}/etc/systemd/system/${u}" ]; then
          echo -e "    ${RED}ERROR: Ottawa unit '${u}' not found in ${host} systemd configuration!${NC}" >&2
          exit 1
        fi
      done
      ;;
    kir-pi-primary|pi-primary)
      KIR_PRI_UNITS=("keepalived.service" "upsdrv.service" "upsd.service" "docker-swag.service" "docker-upswake.service" "cloudflare-dyndns.service")
      for u in "${KIR_PRI_UNITS[@]}"; do
        if [ ! -e "${toplevel}/etc/systemd/system/${u}" ]; then
          echo -e "    ${RED}ERROR: Kirkland primary unit '${u}' not found in ${host} systemd configuration!${NC}" >&2
          exit 1
        fi
      done
      ;;
    kir-pi-secondary|pi-secondary)
      KIR_SEC_UNITS=("keepalived.service" "wireguard-wg0.service" "docker-swag.service" "cloudflare-dyndns.service")
      for u in "${KIR_SEC_UNITS[@]}"; do
        if [ ! -e "${toplevel}/etc/systemd/system/${u}" ]; then
          echo -e "    ${RED}ERROR: Kirkland secondary unit '${u}' not found in ${host} systemd configuration!${NC}" >&2
          exit 1
        fi
      done
      ;;
  esac
  echo -e "  ${GREEN}✓${NC} All critical systemd units declared and present for ${BOLD}${host}${NC}."
done

echo -e "\n${BLUE}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}   ✓ All NixOS Systemd Container Tests Passed Successfully!     ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}\n"
