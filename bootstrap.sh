#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Coolify Server Bootstrap
#
# Intended for fresh Ubuntu VPS instances where:
# - Provider creates an initial sudo user (e.g. ubuntu)
# - SSH key is already installed for that user
# - Server will later be managed by Coolify
#
# Usage:
#
#   ./bootstrap.sh
#
#   ./bootstrap.sh --hostname lds-2
#
#   curl -fsSL https://example.com/bootstrap.sh | \
#     bash -s -- --hostname lds-2
#
# IMPORTANT:
# Run this as the initial non-root user.
# Do NOT run with "sudo bash".
# ============================================================

SWAP_SIZE="2G"
SWAPPINESS="10"
TIMEZONE="UTC"
SERVER_HOSTNAME=""

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

log() {
    echo
    echo "==> $1"
}

error() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)
            [[ $# -ge 2 ]] || error "--hostname requires a value"
            SERVER_HOSTNAME="$2"
            shift 2
            ;;

        --swap-size)
            [[ $# -ge 2 ]] || error "--swap-size requires a value"
            SWAP_SIZE="$2"
            shift 2
            ;;

        --timezone)
            [[ $# -ge 2 ]] || error "--timezone requires a value"
            TIMEZONE="$2"
            shift 2
            ;;

        --help|-h)
            cat <<EOF
Coolify Server Bootstrap

Usage:
  bootstrap.sh [options]

Options:
  --hostname NAME       Set server hostname
  --swap-size SIZE      Swapfile size (default: 2G)
  --timezone ZONE       System timezone (default: UTC)
  --help                Show this help

Example:
  bootstrap.sh --hostname lds-2
EOF
            exit 0
            ;;

        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ------------------------------------------------------------
# Safety checks
# ------------------------------------------------------------

if [[ "$(id -u)" -eq 0 ]]; then
    error "Run this script as the initial non-root user, not as root.

Example:

    curl -fsSL URL/bootstrap.sh | bash -s -- --hostname lds-2

The script will use sudo internally."
fi

command_exists sudo || error "sudo is required."

CURRENT_USER="$(whoami)"
CURRENT_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"

[[ -n "$CURRENT_HOME" ]] || error "Could not determine home directory."

AUTHORIZED_KEYS="$CURRENT_HOME/.ssh/authorized_keys"

if [[ ! -s "$AUTHORIZED_KEYS" ]]; then
    error "No SSH authorized_keys found at:

    $AUTHORIZED_KEYS

Root SSH configuration was not changed."
fi

# Make sudo ask for credentials now rather than halfway through.
sudo -v

echo
echo "============================================"
echo "   Coolify Server Bootstrap"
echo "============================================"
echo
echo "Current user:   $CURRENT_USER"
echo "Current host:   $(hostname)"
echo "Timezone:       $TIMEZONE"
echo "Swap size:      $SWAP_SIZE"

if [[ -n "$SERVER_HOSTNAME" ]]; then
    echo "New hostname:   $SERVER_HOSTNAME"
fi

# ------------------------------------------------------------
# Update OS
# ------------------------------------------------------------

log "Updating Ubuntu"

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive \
    apt-get upgrade -y

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

log "Installing base packages"

sudo DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        ca-certificates \
        gnupg \
        htop \
        nano \
        ufw \
        unattended-upgrades

# ------------------------------------------------------------
# Root SSH keys
# ------------------------------------------------------------

log "Configuring root SSH keys"

sudo install -d \
    -m 700 \
    -o root \
    -g root \
    /root/.ssh

sudo touch /root/.ssh/authorized_keys

sudo chown root:root /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys

# Add all provider-installed keys without duplicating them.
while IFS= read -r key || [[ -n "$key" ]]; do

    # Ignore blank lines and comments.
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue

    if ! sudo grep -qxF "$key" /root/.ssh/authorized_keys; then
        echo "$key" |
            sudo tee -a /root/.ssh/authorized_keys >/dev/null
    fi

done < "$AUTHORIZED_KEYS"

# Verify at least one root key exists.
ROOT_KEY_COUNT="$(
    sudo grep -Ec '^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)' \
        /root/.ssh/authorized_keys \
        || true
)"

if [[ "$ROOT_KEY_COUNT" -eq 0 ]]; then
    error "Root authorized_keys appears to contain no SSH keys."
fi

echo "Root authorized keys: $ROOT_KEY_COUNT"

# ------------------------------------------------------------
# SSH hardening
# ------------------------------------------------------------

log "Configuring SSH"

sudo mkdir -p /etc/ssh/sshd_config.d

sudo tee \
    /etc/ssh/sshd_config.d/99-coolify-hardening.conf \
    >/dev/null <<'EOF'
# Coolify remote server access
#
# Root login is allowed only with SSH keys.
# Password-based authentication is disabled.

PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF

log "Validating SSH configuration"

if ! sudo sshd -t; then
    error "sshd configuration validation failed.

SSH was NOT restarted."
fi

sudo systemctl restart ssh

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

log "Configuring UFW"

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

sudo ufw --force enable

# ------------------------------------------------------------
# Automatic security updates
# ------------------------------------------------------------

log "Configuring unattended security upgrades"

sudo tee \
    /etc/apt/apt.conf.d/20auto-upgrades \
    >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

sudo systemctl enable unattended-upgrades >/dev/null
sudo systemctl restart unattended-upgrades

# ------------------------------------------------------------
# Timezone
# ------------------------------------------------------------

log "Setting timezone to $TIMEZONE"

sudo timedatectl set-timezone "$TIMEZONE"

# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

log "Checking swap"

if [[ "$(swapon --show --noheadings | wc -l)" -eq 0 ]]; then

    echo "Creating $SWAP_SIZE swapfile..."

    sudo fallocate -l "$SWAP_SIZE" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' |
            sudo tee -a /etc/fstab >/dev/null
    fi

else
    echo "Existing swap detected. Leaving it unchanged."
fi

# ------------------------------------------------------------
# Swappiness
# ------------------------------------------------------------

log "Setting swappiness to $SWAPPINESS"

echo "vm.swappiness=$SWAPPINESS" |
    sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null

sudo sysctl -p \
    /etc/sysctl.d/99-swappiness.conf \
    >/dev/null

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

if [[ -n "$SERVER_HOSTNAME" ]]; then
    log "Setting hostname to $SERVER_HOSTNAME"

    sudo hostnamectl set-hostname "$SERVER_HOSTNAME"
fi

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

log "Cleaning packages"

sudo DEBIAN_FRONTEND=noninteractive \
    apt-get autoremove -y

sudo apt-get autoclean -y

# ------------------------------------------------------------
# Final validation
# ------------------------------------------------------------

log "Validating configuration"

sudo sshd -t

echo
echo "============================================"
echo "   Bootstrap Complete"
echo "============================================"

echo
echo "Hostname:"
hostname

echo
echo "Operating system:"
. /etc/os-release
echo "$PRETTY_NAME"

echo
echo "Memory / swap:"
free -h

echo
echo "Disk:"
df -h /

echo
echo "Firewall:"
sudo ufw status

echo
echo "SSH configuration:"
sudo sshd -T |
    grep -E \
    '^(permitrootlogin|passwordauthentication|pubkeyauthentication)'

echo
echo "Timezone:"
timedatectl |
    grep "Time zone"

echo
echo "Root authorized keys:"
sudo grep -Ec \
    '^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)' \
    /root/.ssh/authorized_keys \
    || true

echo
echo "============================================"
echo
echo "IMPORTANT:"
echo
echo "Keep this SSH session open."
echo
echo "From another terminal, verify root login:"
echo

SERVER_IP="$(
    hostname -I |
        awk '{print $1}'
)"

echo "    ssh root@$SERVER_IP"

echo
echo "Once root SSH works, the server is ready"
echo "to be added to Coolify."
echo
