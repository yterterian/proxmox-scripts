#!/usr/bin/env bash
# =============================================================================
# Actual Budget - Quick Install Shortcut
# =============================================================================
# 
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR-USERNAME/proxmox-scripts/main/actualbudget/install.sh)
#
# TODO: Update YOUR-USERNAME below to your GitHub username after creating the repo
#
# =============================================================================

GITHUB_USER="yterterian"
GITHUB_REPO="proxmox-scripts"
GITHUB_BRANCH="main"

SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/actualbudget/standalone/actualbudget-standalone.sh"

exec bash <(curl -fsSL "${SCRIPT_URL}")
