FROM nixos/nix:latest

# Configure Git safe directory for mounted host workspaces
RUN git config --global --add safe.directory '*'

# Copy optimized Nix configuration for cross-architecture builds
COPY docker/nix.conf /etc/nix/nix.conf

# Setup SSH client defaults (system-wide so it persists when host ~/.ssh is mounted)
RUN mkdir -p /etc/ssh /root/.ssh && cat <<'EOF' > /etc/ssh/ssh_config
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /tmp/known_hosts /root/.ssh/known_hosts
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
EOF

# Install nixos-rebuild CLI tool in builder environment
RUN nix-env -f '<nixpkgs>' -iA nixos-rebuild 2>/dev/null || true

# Copy and setup deployment entrypoint script
COPY docker/deploy.sh /usr/local/bin/deploy
RUN chmod +x /usr/local/bin/deploy

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/deploy"]
CMD ["pi-primary", "boot"]
