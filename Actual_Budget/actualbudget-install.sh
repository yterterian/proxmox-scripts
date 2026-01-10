#!/usr/bin/env bash
# =============================================================================
# Actual Budget Installation Script (Optimised)
# =============================================================================
# Copyright (c) 2021-2026 community-scripts ORG
# Author: MickLesk (CanbiZ) | Optimised by: Jack (Downer)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://actualbudget.org/
# =============================================================================
#
# This script runs INSIDE the LXC container to install Actual Budget.
# It is executed via pct exec/lxc-attach during container provisioning.
#
# Features:
#   - Custom MOTD with IP:Port display
#   - Node.js 22 LTS via NodeSource
#   - npm global install for @actual-app/sync-server
#   - Systemd service with auto-restart
#   - Data persistence in /opt/actualbudget-data
#
# =============================================================================

# Source common installation functions
source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"

# Colour definitions (in case not inherited)
RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[36m'
CL='\033[m'
BOLD='\033[1m'

# Application settings
APP="Actual Budget"
ACTUAL_PORT=5006
DATA_DIR="/opt/actualbudget-data"
VERSION_FILE="/opt/actualbudget_version.txt"

# =============================================================================
# MOTD Configuration - Custom Banner
# =============================================================================
setup_custom_motd() {
    msg_info "Configuring custom MOTD"
    
    # Disable default MOTD scripts
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    # Create custom MOTD script
    cat > /etc/profile.d/00_actualbudget-motd.sh << 'MOTD_EOF'
#!/bin/bash
# =============================================================================
# Actual Budget LXC Container - Custom MOTD
# =============================================================================

# Colour definitions
RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[36m'
CL='\033[m'
BOLD='\033[1m'

# Get system information
get_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1 || echo "Unknown"
}

get_os_info() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${NAME:-Unknown} - Version: ${VERSION_ID:-Unknown}"
    else
        echo "Unknown"
    fi
}

get_service_status() {
    if systemctl is-active --quiet actualbudget 2>/dev/null; then
        echo -e "${GN}Running${CL}"
    else
        echo -e "${RD}Stopped${CL}"
    fi
}

get_version() {
    if [[ -f ~/.actualbudget ]]; then
        cat ~/.actualbudget
    elif [[ -f /opt/actualbudget_version.txt ]]; then
        cat /opt/actualbudget_version.txt
    else
        echo "Unknown"
    fi
}

IP_ADDR=$(get_ip)
OS_INFO=$(get_os_info)
HOSTNAME=$(hostname)
SERVICE_STATUS=$(get_service_status)
APP_VERSION=$(get_version)

# Print MOTD
echo ""
echo -e "${BOLD}Actual Budget LXC Container${CL}"
echo -e "    🌐   Provided by: ${GN}community-scripts ORG${CL} | GitHub: ${GN}https://github.com/community-scripts/ProxmoxVE${CL}"
echo -e "    🖥️   OS: ${GN}${OS_INFO}${CL}"
echo -e "    🏠   Hostname: ${GN}${HOSTNAME}${CL}"
echo -e "    💡   IP Address: ${GN}${IP_ADDR}${CL}"
echo ""
echo -e "    📊   ${BOLD}Actual Budget${CL}"
echo -e "         Version: ${GN}${APP_VERSION}${CL}"
echo -e "         Service: ${SERVICE_STATUS}"
echo -e "         Web UI:  ${GN}http://${IP_ADDR}:5006${CL}"
echo ""
MOTD_EOF

    chmod +x /etc/profile.d/00_actualbudget-motd.sh
    
    # Create static /etc/motd for non-interactive access
    cat > /etc/motd << 'STATIC_MOTD_EOF'

Actual Budget LXC Container
    🌐   Provided by: community-scripts ORG | GitHub: https://github.com/community-scripts/ProxmoxVE

    Run 'update' to check for application updates.
    
STATIC_MOTD_EOF

    msg_ok "Configured custom MOTD"
}

# =============================================================================
# Node.js Installation
# =============================================================================
install_nodejs() {
    msg_info "Installing Node.js 22 LTS"
    
    # Install prerequisites
    $STD apt-get update
    $STD apt-get install -y ca-certificates curl gnupg
    
    # Setup NodeSource repository
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    
    NODE_MAJOR=22
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    
    $STD apt-get update
    $STD apt-get install -y nodejs
    
    # Verify installation
    NODE_VER=$(node --version)
    NPM_VER=$(npm --version)
    
    msg_ok "Installed Node.js ${NODE_VER} with npm ${NPM_VER}"
}

# =============================================================================
# Actual Budget Installation
# =============================================================================
install_actualbudget() {
    msg_info "Installing Actual Budget"
    
    # Create data directory
    mkdir -p "${DATA_DIR}"
    
    # Install Actual Budget sync server globally
    $STD npm install -g @actual-app/sync-server
    
    # Get installed version
    RELEASE=$(npm list -g @actual-app/sync-server --json 2>/dev/null | grep -o '"version": "[^"]*' | head -1 | cut -d'"' -f4)
    if [[ -z "$RELEASE" ]]; then
        RELEASE="latest"
    fi
    
    echo "${RELEASE}" > ~/.actualbudget
    echo "${RELEASE}" > "${VERSION_FILE}"
    
    msg_ok "Installed Actual Budget ${RELEASE}"
}

# =============================================================================
# Systemd Service Configuration
# =============================================================================
setup_service() {
    msg_info "Configuring systemd service"
    
    cat > /etc/systemd/system/actualbudget.service << 'SERVICE_EOF'
[Unit]
Description=Actual Budget Sync Server
Documentation=https://actualbudget.org/docs/
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/actualbudget-data
Environment=NODE_ENV=production
Environment=ACTUAL_DATA_DIR=/opt/actualbudget-data
ExecStart=/usr/bin/actual-server
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/opt/actualbudget-data
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    # Reload and enable service
    systemctl daemon-reload
    systemctl enable actualbudget
    
    msg_ok "Configured systemd service"
}

# =============================================================================
# Create Update Script
# =============================================================================
setup_update_script() {
    msg_info "Creating update script"
    
    cat > /usr/bin/update << 'UPDATE_EOF'
#!/bin/bash
# Actual Budget Update Script
# Run this to update to the latest version

set -e

echo "==================================="
echo "  Actual Budget Update Script"
echo "==================================="
echo ""

CURRENT_VERSION=$(cat ~/.actualbudget 2>/dev/null || echo "unknown")
echo "Current version: ${CURRENT_VERSION}"
echo ""

echo "Checking for updates..."
LATEST=$(npm view @actual-app/sync-server version 2>/dev/null || echo "error")

if [[ "$LATEST" == "error" ]]; then
    echo "Error: Could not check for updates. Check your internet connection."
    exit 1
fi

echo "Latest version:  ${LATEST}"
echo ""

if [[ "$CURRENT_VERSION" == "$LATEST" ]]; then
    echo "✓ You are already running the latest version!"
    exit 0
fi

read -p "Update to ${LATEST}? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Stopping Actual Budget service..."
    systemctl stop actualbudget
    
    echo "Updating Actual Budget..."
    npm update -g @actual-app/sync-server
    
    echo "${LATEST}" > ~/.actualbudget
    echo "${LATEST}" > /opt/actualbudget_version.txt
    
    echo "Starting Actual Budget service..."
    systemctl start actualbudget
    
    echo ""
    echo "✓ Successfully updated to ${LATEST}!"
else
    echo "Update cancelled."
fi
UPDATE_EOF

    chmod +x /usr/bin/update
    
    msg_ok "Created update script"
}

# =============================================================================
# Main Installation Flow
# =============================================================================
main() {
    # Set verbose mode handler
    set_std_mode
    
    msg_info "Setting up Container OS"
    setting_up_container
    msg_ok "Set up Container OS"
    
    network_check
    update_os
    
    install_nodejs
    install_actualbudget
    setup_service
    setup_custom_motd
    setup_update_script
    
    # Start the service
    msg_info "Starting Actual Budget"
    systemctl start actualbudget
    
    # Wait for service to be ready
    sleep 3
    
    if systemctl is-active --quiet actualbudget; then
        msg_ok "Started Actual Budget"
    else
        msg_error "Failed to start Actual Budget - check 'journalctl -u actualbudget' for details"
    fi
    
    # Configure SSH if enabled
    motd_ssh
    customize
    
    msg_info "Cleaning up"
    $STD apt-get -y autoremove
    $STD apt-get -y autoclean
    msg_ok "Cleaned up"
}

# Run main function
main
