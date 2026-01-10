#!/usr/bin/env bash
# =============================================================================
# Actual Budget - Standalone LXC Installation Script
# =============================================================================
# 
# This is a STANDALONE script that installs Actual Budget in an existing
# Debian/Ubuntu LXC container. It does not require the community-scripts
# framework and can be customised freely.
#
# Usage:
#   1. Create a Debian 12/13 or Ubuntu 22.04/24.04 LXC container in Proxmox
#   2. SSH/console into the container
#   3. Run: bash <(curl -fsSL https://your-host/actualbudget-standalone.sh)
#
# Or upload this script and run: bash actualbudget-standalone.sh
#
# Author: Jack (Downer) - Optimised from community-scripts
# License: MIT
# Source: https://actualbudget.org/
#
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
APP_NAME="Actual Budget"
APP_PORT=5006
DATA_DIR="/opt/actualbudget-data"
NODE_VERSION=22

# Colours
RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[36m'
CL='\033[m'
BOLD='\033[1m'
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

# =============================================================================
# Helper Functions
# =============================================================================
msg_info() {
    local msg="$1"
    echo -e " - ${YW}${msg}...${CL}"
}

msg_ok() {
    local msg="$1"
    echo -e " ${CM} ${GN}${msg}${CL}"
}

msg_error() {
    local msg="$1"
    echo -e " ${CROSS} ${RD}${msg}${CL}"
}

header() {
    clear
    cat << 'EOF'
    _        _               _   ____            _            _   
   / \   ___| |_ _   _  __ _| | | __ ) _   _  __| | __ _  ___| |_ 
  / _ \ / __| __| | | |/ _` | | |  _ \| | | |/ _` |/ _` |/ _ \ __|
 / ___ \ (__| |_| |_| | (_| | | | |_) | |_| | (_| | (_| |  __/ |_ 
/_/   \_\___|\__|\__,_|\__,_|_| |____/ \__,_|\__,_|\__, |\___|\__|
                                                   |___/           
EOF
    echo ""
    echo -e "${BOLD}Standalone LXC Installation Script${CL}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
        exit 1
    fi
}

get_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || \
    ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1 || \
    echo "Unknown"
}

# =============================================================================
# Installation Functions
# =============================================================================

install_dependencies() {
    msg_info "Updating system packages"
    apt-get update -qq
    apt-get upgrade -y -qq
    msg_ok "Updated system packages"
    
    msg_info "Installing dependencies"
    apt-get install -y -qq curl gnupg ca-certificates
    msg_ok "Installed dependencies"
}

install_nodejs() {
    msg_info "Installing Node.js ${NODE_VERSION} LTS"
    
    # Setup NodeSource repository
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" > \
        /etc/apt/sources.list.d/nodesource.list
    
    apt-get update -qq
    apt-get install -y -qq nodejs
    
    # Configure npm global directory
    mkdir -p /root/.npm-global
    npm config set prefix '/root/.npm-global'
    echo 'export PATH=/root/.npm-global/bin:$PATH' >> /root/.bashrc
    export PATH=/root/.npm-global/bin:$PATH
    
    msg_ok "Installed Node.js $(node --version)"
}

install_actualbudget() {
    msg_info "Installing Actual Budget"
    
    # Create data directory
    mkdir -p "${DATA_DIR}"
    
    # Install via npm (using global path)
    export PATH=/root/.npm-global/bin:$PATH
    npm install -g @actual-app/sync-server
    
    # Get version
    RELEASE=$(npm list -g @actual-app/sync-server --json 2>/dev/null | \
        grep -o '"version": "[^"]*' | head -1 | cut -d'"' -f4 || echo "latest")
    
    echo "${RELEASE}" > ~/.actualbudget
    echo "${RELEASE}" > "${DATA_DIR}/version.txt"
    
    msg_ok "Installed Actual Budget ${RELEASE}"
}

setup_systemd_service() {
    msg_info "Creating systemd service"
    
    cat > /etc/systemd/system/actualbudget.service << EOF
[Unit]
Description=Actual Budget Sync Server
Documentation=https://actualbudget.org/docs/
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
Environment=NODE_ENV=production
Environment=ACTUAL_DATA_DIR=${DATA_DIR}
Environment=PATH=/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/root/.npm-global/bin/actual-server
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable actualbudget
    
    msg_ok "Created systemd service"
}

setup_motd() {
    msg_info "Configuring MOTD banner"
    
    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    # Create custom MOTD script that runs on login
    cat > /etc/profile.d/00_actualbudget-motd.sh << 'MOTD_SCRIPT'
#!/bin/bash
# Actual Budget MOTD - Displays on console/SSH login

# Colours
RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[36m'
CL='\033[m'
BOLD='\033[1m'

# Gather info
get_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "Unknown"
}

get_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${NAME:-Linux} - Version: ${VERSION_ID:-Unknown}"
    else
        echo "Unknown"
    fi
}

get_status() {
    if systemctl is-active --quiet actualbudget 2>/dev/null; then
        echo -e "${GN}● Running${CL}"
    else
        echo -e "${RD}● Stopped${CL}"
    fi
}

get_version() {
    cat ~/.actualbudget 2>/dev/null || cat /opt/actualbudget-data/version.txt 2>/dev/null || echo "Unknown"
}

IP=$(get_ip)
OS=$(get_os)
HN=$(hostname)
STATUS=$(get_status)
VER=$(get_version)

echo ""
echo -e "${BOLD}Actual Budget LXC Container${CL}"
echo -e "    🌐   Provided by: ${GN}community-scripts ORG${CL} | GitHub: ${GN}https://github.com/community-scripts/ProxmoxVE${CL}"
echo -e "    🖥️   OS: ${GN}${OS}${CL}"
echo -e "    🏠   Hostname: ${GN}${HN}${CL}"
echo -e "    💡   IP Address: ${GN}${IP}${CL}"
echo ""
echo -e "    📊   Service Status: ${STATUS}"
echo -e "    📦   Version: ${GN}${VER}${CL}"
echo -e "    🌍   Web UI: ${GN}http://${IP}:5006${CL}"
echo ""
echo -e "    💡   Run '${YW}update${CL}' to check for new versions"
echo ""
MOTD_SCRIPT

    chmod +x /etc/profile.d/00_actualbudget-motd.sh
    
    msg_ok "Configured MOTD banner"
}

setup_update_script() {
    msg_info "Creating update utility"
    
    cat > /usr/local/bin/update << 'UPDATE_SCRIPT'
#!/bin/bash
# Actual Budget Update Utility

set -e

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "              Actual Budget Update Utility"
echo "═══════════════════════════════════════════════════════════════"
echo ""

export PATH=/root/.npm-global/bin:$PATH

CURRENT=$(cat ~/.actualbudget 2>/dev/null || echo "unknown")
echo "📦 Current version: ${CURRENT}"

echo "🔍 Checking for updates..."
LATEST=$(npm view @actual-app/sync-server version 2>/dev/null)

if [[ -z "$LATEST" ]]; then
    echo "❌ Error: Could not check for updates. Check your internet connection."
    exit 1
fi

echo "📦 Latest version:  ${LATEST}"
echo ""

if [[ "$CURRENT" == "$LATEST" ]]; then
    echo "✅ You are already running the latest version!"
    exit 0
fi

echo "📥 Update available: ${CURRENT} → ${LATEST}"
echo ""
read -p "Proceed with update? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "⏸️  Stopping Actual Budget..."
    systemctl stop actualbudget
    
    echo "📦 Updating to ${LATEST}..."
    npm update -g @actual-app/sync-server
    
    echo "${LATEST}" > ~/.actualbudget
    echo "${LATEST}" > /opt/actualbudget-data/version.txt
    
    echo "▶️  Starting Actual Budget..."
    systemctl start actualbudget
    
    sleep 2
    
    if systemctl is-active --quiet actualbudget; then
        echo ""
        echo "✅ Successfully updated to ${LATEST}!"
        echo "🌍 Access at: http://$(hostname -I | awk '{print $1}'):5006"
    else
        echo ""
        echo "⚠️  Service may not have started correctly."
        echo "   Check logs with: journalctl -u actualbudget -n 50"
    fi
else
    echo "❌ Update cancelled."
fi
UPDATE_SCRIPT

    chmod +x /usr/local/bin/update
    
    msg_ok "Created update utility"
}

cleanup() {
    msg_info "Cleaning up"
    apt-get autoremove -y -qq
    apt-get autoclean -y -qq
    msg_ok "Cleaned up"
}

start_service() {
    msg_info "Starting Actual Budget"
    
    systemctl start actualbudget
    sleep 3
    
    if systemctl is-active --quiet actualbudget; then
        msg_ok "Started Actual Budget"
    else
        msg_error "Service failed to start - check: journalctl -u actualbudget"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    header
    check_root
    
    IP=$(get_ip)
    echo -e "Container IP: ${GN}${IP}${CL}"
    echo ""
    
    install_dependencies
    install_nodejs
    install_actualbudget
    setup_systemd_service
    setup_motd
    setup_update_script
    cleanup
    start_service
    
    echo ""
    echo -e "═══════════════════════════════════════════════════════════════"
    echo -e "${GN}${BOLD}Installation Complete!${CL}"
    echo -e "═══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "    🌍 Access Actual Budget at: ${GN}http://${IP}:${APP_PORT}${CL}"
    echo ""
    echo -e "    📋 Useful commands:"
    echo -e "       ${YW}update${CL}              - Check for and apply updates"
    echo -e "       ${YW}systemctl status actualbudget${CL}  - Check service status"
    echo -e "       ${YW}journalctl -u actualbudget -f${CL}  - View live logs"
    echo ""
    echo -e "    📁 Data directory: ${YW}${DATA_DIR}${CL}"
    echo ""
}

main "$@"
