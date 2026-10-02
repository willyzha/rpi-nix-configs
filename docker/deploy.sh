#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Docker Rebuild & Deployment Script for Raspberry Pi NixOS
# Auto-detects node identity (pi-primary vs pi-secondary) from IP address.
# ==============================================================================

DEFAULT_ACTION="boot"
DEFAULT_USER="root"
DEFAULT_KEY=""

# Color helpers
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

print_usage() {
  cat <<EOF
${BOLD}Usage:${NC}
  ./docker-rebuild.sh [IP_ADDRESS | TARGET_HOST] [ACTION]
  docker compose run --rm rebuild [IP_ADDRESS | TARGET_HOST] [ACTION]

${BOLD}Quick Examples (Auto-detect by IP):${NC}
  ./docker-rebuild.sh 192.168.1.12           # Auto-detects pi-secondary, rebuilds & reboots
  ./docker-rebuild.sh 192.168.1.11           # Auto-detects pi-primary, rebuilds & reboots
  ./docker-rebuild.sh 192.168.1.12 switch    # Rebuilds & switches live services immediately
  ./docker-rebuild.sh 192.168.1.11 test      # Tests build without modifying bootloader

${BOLD}By Hostname:${NC}
  ./docker-rebuild.sh pi-primary
  ./docker-rebuild.sh pi-secondary
  ./docker-rebuild.sh pi-primary build-only  # Builds locally in Docker (~2s cached, no Pi needed)
  ./docker-rebuild.sh pi-primary image       # Generates flashable SD card image in ./output/

${BOLD}Actions:${NC}
  boot        (Default) Build on host, copy to Pi, set next boot generation, and clean reboot.
              Recommended for 1GB Pi 3B to avoid runtime service restart brownouts.
  switch      Build on host, copy to Pi, and switch live services immediately.
  test        Build on host, copy to Pi, and test services without updating bootloader.
  build-only  Build system toplevel locally in Docker without connecting to the Pi.
  image       Build complete bootable SD card image and place it in ./output/.
  shell       Open an interactive bash shell in the build environment.

${BOLD}Environment Variables:${NC}
  TARGET_IP       Target IP address or hostname
  TARGET_HOST     Override auto-detection (pi-primary or pi-secondary)
  ACTION          Deployment action (default: boot)
  TARGET_USER     Remote SSH user (default: root)
  SSH_KEY         Explicit private SSH key path (optional, auto-discovers all keys in ~/.ssh by default)
  REBOOT          Reboot target after 'boot' action (default: true)
EOF
}

# Check for help
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  print_usage
  exit 0
fi

# Shell override
if [[ "${1:-}" == "shell" || "${1:-}" == "bash" ]]; then
  exec /usr/bin/env bash
fi

is_ip_or_address() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$val" =~ \.local$ || "$val" =~ : ]]
}

is_action() {
  local val="$1"
  [[ "$val" =~ ^(boot|switch|test|dry-build|dry-activate|build-only|build|image|shell|bash)$ ]]
}

# 1. Parse Arguments & Environment Variables
RAW_ARG1="${1:-}"
RAW_ARG2="${2:-}"
RAW_ARG3="${3:-}"

TARGET_IP="${TARGET_IP:-}"
TARGET_HOST="${TARGET_HOST:-}"
ACTION="${ACTION:-$DEFAULT_ACTION}"
TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"
SSH_KEY="${SSH_KEY:-$DEFAULT_KEY}"
REBOOT="${REBOOT:-true}"

# Smart Argument Classification:
if [ -n "$RAW_ARG1" ]; then
  if is_ip_or_address "$RAW_ARG1"; then
    # e.g.: ./docker-rebuild.sh 192.168.1.12 [ACTION]
    TARGET_IP="$RAW_ARG1"
    TARGET_HOST=""
    if [ -n "$RAW_ARG2" ]; then
      ACTION="$RAW_ARG2"
    fi
  elif is_action "$RAW_ARG1"; then
    # e.g.: ./docker-rebuild.sh build-only [TARGET]
    ACTION="$RAW_ARG1"
    if [ -n "$RAW_ARG2" ]; then
      if is_ip_or_address "$RAW_ARG2"; then
        TARGET_IP="$RAW_ARG2"
        TARGET_HOST=""
      else
        TARGET_HOST="$RAW_ARG2"
      fi
    fi
  else
    # e.g.: ./docker-rebuild.sh pi-primary [ACTION] [IP]
    TARGET_HOST="$RAW_ARG1"
    if [ -n "$RAW_ARG2" ]; then
      if is_action "$RAW_ARG2"; then
        ACTION="$RAW_ARG2"
        if [ -n "$RAW_ARG3" ]; then
          TARGET_IP="$RAW_ARG3"
        fi
      elif is_ip_or_address "$RAW_ARG2"; then
        TARGET_IP="$RAW_ARG2"
      fi
    fi
  fi
fi

# Ensure git repository is trusted by root inside container
git config --global --add safe.directory /workspace 2>/dev/null || true
git config --global --add safe.directory '*' 2>/dev/null || true

# Determine flake reference (local workspace or remote GitHub repository)
FLAKE_REF="${FLAKE_REF:-}"
if [ -z "$FLAKE_REF" ]; then
  if [ -f "/workspace/flake.nix" ]; then
    FLAKE_REF="/workspace"
  else
    FLAKE_REF="github:willyzha/rpi-nix-configs"
  fi
fi

if [[ "$FLAKE_REF" == "/workspace" ]]; then
  cd /workspace
  git config --global --add safe.directory /workspace 2>/dev/null || true
fi

# Check if host ssh-agent socket is forwarded
if [ -S "/ssh-agent" ]; then
  export SSH_AUTH_SOCK="/ssh-agent"
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts -o UserKnownHostsFile=/root/.ssh/known_hosts -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

KEY_OPTS=""
FOUND_KEYS=()

if [ -n "${SSH_KEY:-}" ] && [ -f "$SSH_KEY" ]; then
  # User explicitly specified a key
  KEY_OPTS="-i $SSH_KEY"
  FOUND_KEYS+=("$SSH_KEY")
elif [ -d "/root/.ssh" ]; then
  # Auto-discover all private keys in /root/.ssh
  # 1. Standard OpenSSH identity keys first
  for k in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa /root/.ssh/id_ecdsa_sk /root/.ssh/id_ed25519_sk /root/.ssh/id_dsa; do
    if [ -f "$k" ]; then
      KEY_OPTS="$KEY_OPTS -i $k"
      FOUND_KEYS+=("$k")
    fi
  done

  # 2. Any additional private keys found in ~/.ssh (files containing 'PRIVATE KEY')
  for f in /root/.ssh/*; do
    if [ -f "$f" ] && [[ ! "$f" =~ \.pub$ ]] && [[ ! " ${FOUND_KEYS[*]:-} " =~ " ${f} " ]]; then
      if grep -q "PRIVATE KEY" "$f" 2>/dev/null; then
        KEY_OPTS="$KEY_OPTS -i $f"
        FOUND_KEYS+=("$f")
      fi
    fi
  done
fi

if [ -n "$KEY_OPTS" ]; then
  SSH_OPTS="$SSH_OPTS $KEY_OPTS"
fi

# ------------------------------------------------------------------------------
# Auto-detect Target Host & IP if needed
# ------------------------------------------------------------------------------
if [[ "$ACTION" != "build-only" && "$ACTION" != "build" && "$ACTION" != "image" ]]; then
  # If TARGET_IP is not given, but TARGET_HOST is known:
  if [ -z "$TARGET_IP" ]; then
    case "$TARGET_HOST" in
      pi-primary)
        TARGET_IP="192.168.1.11"
        ;;
      pi-secondary)
        TARGET_IP="192.168.1.12"
        ;;
      *)
        # Try probing known nodes
        echo -e "${YELLOW}No target specified. Probing known nodes...${NC}"
        if ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=2 "${TARGET_USER}@192.168.1.11" "true" 2>/dev/null; then
          TARGET_IP="192.168.1.11"
        elif ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=2 "${TARGET_USER}@192.168.1.12" "true" 2>/dev/null; then
          TARGET_IP="192.168.1.12"
        else
          echo -e "${RED}Error: No target node specified and neither 192.168.1.11 nor 192.168.1.12 is reachable.${NC}" >&2
          echo -e "Usage: ./docker-rebuild.sh <IP_ADDRESS|HOST> [ACTION]" >&2
          exit 1
        fi
        ;;
    esac
  fi

  # Step 1: Pre-Flight Connectivity & Remote Hostname Auto-Detection
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  echo -e "${BLUE}${BOLD}   Raspberry Pi NixOS Host Builder & Deployer (Docker)           ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  echo -e "  Connecting To : ${BOLD}$TARGET_IP${NC} (user: $TARGET_USER)"
  echo -e "  Action        : ${BOLD}$ACTION${NC}"
  echo -e "  Flake Source  : ${BOLD}$FLAKE_REF${NC}"
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    echo -e "  SSH Agent     : ${GREEN}Active (forwarded socket)${NC}"
  fi
  if [ ${#FOUND_KEYS[@]} -gt 0 ]; then
    echo -e "  SSH Keys Found: ${BOLD}${FOUND_KEYS[*]}${NC}"
  else
    echo -e "  SSH Keys Found: (none detected, relying on default agent/system)"
  fi
  echo -e "${BLUE}----------------------------------------------------------------${NC}"

  echo -e "\n${GREEN}==> Step 1/5: Connecting to ${TARGET_USER}@${TARGET_IP} & detecting node identity...${NC}"
  if ! ssh $SSH_OPTS -o BatchMode=yes "${TARGET_USER}@${TARGET_IP}" "true" 2>/dev/null; then
    echo -e "${RED}Error: Cannot connect to ${TARGET_USER}@${TARGET_IP} via SSH!${NC}" >&2
    echo -e "  Diagnostics:" >&2
    echo -e "  - Is the Raspberry Pi powered on and connected to the network?" >&2
    echo -e "  - Is the IP address correct? (Try: ./docker-rebuild.sh <ACTUAL_IP>)" >&2
    if [ ${#FOUND_KEYS[@]} -gt 0 ]; then
      echo -e "  - Keys attempted: ${FOUND_KEYS[*]}" >&2
      echo -e "    Ensure root's authorized_keys on the Pi contains the corresponding public key." >&2
    else
      echo -e "  - No SSH private keys found in ~/.ssh. Ensure your keys are placed in ~/.ssh on the host." >&2
    fi
    exit 1
  fi

  # Query remote hostname
  DETECTED_HOSTNAME=$(ssh $SSH_OPTS -o BatchMode=yes "${TARGET_USER}@${TARGET_IP}" "cat /proc/sys/kernel/hostname 2>/dev/null || hostname" 2>/dev/null | tr -d '\r\n[:space:]' || true)

  if [ -n "$DETECTED_HOSTNAME" ]; then
    echo -e "  ${GREEN}✓ Connected!${NC} Node identified as: ${BOLD}${DETECTED_HOSTNAME}${NC}"
    if [ -z "$TARGET_HOST" ]; then
      TARGET_HOST="$DETECTED_HOSTNAME"
    elif [ "$TARGET_HOST" != "$DETECTED_HOSTNAME" ]; then
      echo -e "  ${YELLOW}Notice: Node reported hostname '${DETECTED_HOSTNAME}', but '${TARGET_HOST}' was explicitly set.${NC}"
      echo -e "  Using explicit configuration: ${BOLD}${TARGET_HOST}${NC}"
    fi
  else
    if [ -z "$TARGET_HOST" ]; then
      case "$TARGET_IP" in
        192.168.1.11) TARGET_HOST="kir-pi-primary" ;;
        192.168.1.12) TARGET_HOST="kir-pi-secondary" ;;
        *)
          echo -e "${RED}Error: Could not auto-detect node hostname from ${TARGET_IP}.${NC}" >&2
          echo -e "Please specify target configuration name (e.g. ./docker-rebuild.sh pi-primary boot $TARGET_IP)" >&2
          exit 1
          ;;
      esac
    fi
  fi
else
  # For local-only actions (build-only, image)
  if [ -z "$TARGET_HOST" ]; then
    if [ -n "$TARGET_IP" ]; then
      case "$TARGET_IP" in
        192.168.1.11) TARGET_HOST="kir-pi-primary" ;;
        192.168.1.12) TARGET_HOST="kir-pi-secondary" ;;
        *)
          # Quick attempt to query remote host if available
          TARGET_HOST=$(ssh $SSH_OPTS -o BatchMode=yes -o ConnectTimeout=2 "${TARGET_USER}@${TARGET_IP}" "cat /proc/sys/kernel/hostname 2>/dev/null || hostname" 2>/dev/null | tr -d '\r\n[:space:]' || true)
          ;;
      esac
    fi
    TARGET_HOST="${TARGET_HOST:-pi-primary}"
  fi

  echo -e "${BLUE}${BOLD}================================================================${NC}"
  echo -e "${BLUE}${BOLD}   Raspberry Pi NixOS Host Builder (Docker)                      ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  echo -e "  Target Config : ${BOLD}$TARGET_HOST${NC}"
  echo -e "  Action        : ${BOLD}$ACTION${NC}"
  echo -e "  Flake Source  : ${BOLD}$FLAKE_REF${NC}"
  echo -e "${BLUE}----------------------------------------------------------------${NC}"
fi

# Verify TARGET_HOST exists in flake
if ! nix eval --extra-experimental-features "nix-command flakes" "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.networking.hostName" >/dev/null 2>&1; then
  echo -e "${RED}Error: NixOS configuration '${TARGET_HOST}' not found in flake (${FLAKE_REF})!${NC}" >&2
  echo -e "  Available configurations in flake:" >&2
  echo -e "    - kir-pi-primary" >&2
  echo -e "    - kir-pi-secondary" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Action: image (Build bootable SD card image)
# ------------------------------------------------------------------------------
if [ "$ACTION" = "image" ]; then
  echo -e "\n${GREEN}==> Building bootable SD card image for ${TARGET_HOST}...${NC}"
  OUTPUT_DIR="/workspace/output"
  if [ ! -d "/workspace" ]; then
    OUTPUT_DIR="/tmp/output"
  fi
  mkdir -p "$OUTPUT_DIR"
  nix build \
    --extra-experimental-features "nix-command flakes" \
    --option extra-platforms "aarch64-linux armv7l-linux" \
    --out-link "${OUTPUT_DIR}/${TARGET_HOST}-sd-image" \
    "${FLAKE_REF}#packages.aarch64-linux.${TARGET_HOST}-image"

  echo -e "\n${GREEN}${BOLD}==> SD Card Image Built Successfully!${NC}"
  IMAGE_FILE=$(find "${OUTPUT_DIR}/${TARGET_HOST}-sd-image" -name "*.img.zst" -o -name "*.img" 2>/dev/null | head -n 1 || true)
  if [ -n "$IMAGE_FILE" ]; then
    echo -e "  Image Location: ${BOLD}$IMAGE_FILE${NC}"
    echo -e "  To flash to an SD card (e.g. /dev/sdX):"
    echo -e "    zstdcat $IMAGE_FILE | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
  else
    echo -e "  Image outputs available in: ${BOLD}${OUTPUT_DIR}/${TARGET_HOST}-sd-image${NC}"
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# Action: build-only (Compile / evaluate without deploying)
# ------------------------------------------------------------------------------
if [[ "$ACTION" == "build-only" || "$ACTION" == "build" ]]; then
  echo -e "\n${GREEN}==> Building NixOS system toplevel for ${TARGET_HOST} locally on host...${NC}"
  TOPLEVEL=$(nix build \
    --extra-experimental-features "nix-command flakes" \
    --option extra-platforms "aarch64-linux armv7l-linux" \
    --no-link \
    --print-out-paths \
    "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.system.build.toplevel")

  echo -e "\n${GREEN}${BOLD}==> Build Completed Successfully!${NC}"
  echo -e "  System Toplevel: ${BOLD}$TOPLEVEL${NC}"
  echo -e "  The system closure is now compiled and cached in the Docker Nix store volume."
  exit 0
fi

# ------------------------------------------------------------------------------
# SD Card Zero-Wear Protection: Remount target / and /boot/firmware RW
# Set cleanup trap to ensure target is ALWAYS restored to Read-Only on exit/error
# ------------------------------------------------------------------------------
TARGET_REMOUNTED_RW=false
cleanup() {
  local EXIT_CODE=$?
  if [ "$TARGET_REMOUNTED_RW" = "true" ]; then
    echo -e "\n${YELLOW}==> [Trap] Restoring ${TARGET_IP} partitions to Read-Only...${NC}"
    ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "sync; mount -o remount,ro /boot/firmware 2>/dev/null || true; mount -o remount,ro / 2>/dev/null || true" 2>/dev/null || true
  fi
  exit $EXIT_CODE
}
trap cleanup EXIT INT TERM

echo -e "\n${GREEN}==> Step 2/5: Remounting target / and /boot/firmware as Read-Write...${NC}"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "mount -o remount,rw / && (mountpoint -q /boot/firmware && mount -o remount,rw /boot/firmware || true)"
TARGET_REMOUNTED_RW=true
echo -e "  Target partitions are writable for store updates."

# ------------------------------------------------------------------------------
# Build on Host (Fast Host CPU, Host RAM, Host Network)
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> Step 3/5: Building NixOS system toplevel on host (${TARGET_HOST})...${NC}"
START_TIME=$(date +%s)

TOPLEVEL=$(nix build \
  --extra-experimental-features "nix-command flakes" \
  --option extra-platforms "aarch64-linux armv7l-linux" \
  --no-link \
  --print-out-paths \
  "${FLAKE_REF}#nixosConfigurations.${TARGET_HOST}.config.system.build.toplevel")

BUILD_DURATION=$(( $(date +%s) - START_TIME ))
echo -e "  Host build finished in ${BOLD}${BUILD_DURATION}s${NC}: $TOPLEVEL"

# ------------------------------------------------------------------------------
# Copy Closure to Target Pi
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> Step 4/5: Transferring closure deltas to ${TARGET_IP} via SSH...${NC}"
COPY_START=$(date +%s)

# Use nix copy over SSH (exports NIX_SSHOPTS so all discovered keys and options are used)
export NIX_SSHOPTS="$SSH_OPTS"
nix copy --extra-experimental-features "nix-command flakes" --to "ssh://${TARGET_USER}@${TARGET_IP}" "$TOPLEVEL"

COPY_DURATION=$(( $(date +%s) - COPY_START ))
echo -e "  Transfer completed in ${BOLD}${COPY_DURATION}s${NC}."

# ------------------------------------------------------------------------------
# Activate Configuration on Target
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==> Step 5/5: Activating configuration (${ACTION}) on ${TARGET_IP}...${NC}"

# Set the system profile generation
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "nix-env -p /nix/var/nix/profiles/system --set $TOPLEVEL"

# Run switch-to-configuration
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "$TOPLEVEL/bin/switch-to-configuration $ACTION"

# Commit any pending overlay changes to SD card if tool is installed
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "if command -v rpi-persist-save >/dev/null 2>&1; then rpi-persist-save || true; fi"

# Sync disks and restore Read-Only protection
echo -e "\n${GREEN}==> Restoring SD card Read-Only protection...${NC}"
ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "sync && mount -o remount,ro /boot/firmware 2>/dev/null || true; mount -o remount,ro / 2>/dev/null || true"
TARGET_REMOUNTED_RW=false
echo -e "  Root and firmware partitions restored to Read-Only."

TOTAL_DURATION=$(( $(date +%s) - START_TIME ))

# Reboot if action is 'boot' or REBOOT=true
if [[ "$ACTION" == "boot" && "$REBOOT" == "true" ]]; then
  echo -e "\n${GREEN}${BOLD}==> Rebuild Successful! Triggering clean reboot on ${TARGET_IP}...${NC}"
  ssh $SSH_OPTS "${TARGET_USER}@${TARGET_IP}" "sleep 1 && reboot" 2>/dev/null || true
  echo -e "  Reboot command issued. The node (${TARGET_HOST}) will boot into the new generation in ~30 seconds."
else
  echo -e "\n${GREEN}${BOLD}==> Deployment Complete!${NC}"
  echo -e "  Action '$ACTION' applied successfully in ${BOLD}${TOTAL_DURATION}s${NC}."
fi

echo -e "\n${BLUE}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}   Update Successfully Deployed to ${TARGET_HOST}!              ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}\n"
