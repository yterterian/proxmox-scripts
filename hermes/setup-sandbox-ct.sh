#!/usr/bin/env bash
# =============================================================================
# File: hermes/setup-sandbox-ct.sh
#
# Disposable Docker sandbox for Hermes' terminal/code-execution.
# Run on the PROXMOX HOST as root.
#
# Architecture:
#   CT 100 (Hermes/Simba, holds secrets)  --ssh-->  CT 105 (sandbox, runs Docker)
#   Hermes terminal.backend=docker + DOCKER_HOST=ssh://sandbox@<sandbox-ip>
#   => shell containers run ON 105, never on 100
#   => secrets stay on 100; the sandbox CT is the disposable boundary
#
# Keep terminal CLI-ONLY (already removed from the Telegram toolset).
# =============================================================================
set -euo pipefail

# ---- settings ---------------------------------------------------------------
SANDBOX_CTID="105"
HERMES_CTID="100"
SANDBOX_IP_CIDR="${SANDBOX_IP_CIDR:-}"
SANDBOX_GW="${SANDBOX_GW:-}"
SANDBOX_ADDR=""
BRIDGE="vmbr0"
STORAGE="local-lvm"
CORES="2"; RAM="2048"; DISK="30"
SANDBOX_USER="sandbox"
SANDBOX_IMAGE="nikolaik/python-nodejs:python3.13-nodejs24"
HERMES_USER="hermes"
KEY_PATH="/home/hermes/.ssh/sandbox_docker"
OUTPUT_DIR="/home/hermes/.hermes/cache/documents"
OUTPUT_MOUNT="${OUTPUT_DIR}:/output"

# ---- output helpers ---------------------------------------------------------
GN=$'\033[1;92m'; YW=$'\033[33m'; RD=$'\033[01;31m'; CL=$'\033[m'
info(){ echo -e " ${YW}»${CL} $1"; }
ok(){ echo -e " ${GN}✓${CL} $1"; }
die(){ echo -e " ${RD}✗ $1${CL}"; exit 1; }

# ---- preflight --------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pct >/dev/null || die "pct not found — run on a Proxmox VE host."
pct status "$HERMES_CTID" >/dev/null 2>&1 || die "Hermes CT $HERMES_CTID not found."
pct status "$SANDBOX_CTID" >/dev/null 2>&1 && die "CT $SANDBOX_CTID already exists — pick a free ID or destroy it first."

if [[ -n "$SANDBOX_IP_CIDR" ]]; then
  [[ -n "$SANDBOX_GW" ]] || die "SANDBOX_GW is required when SANDBOX_IP_CIDR is set."
  NET0="name=eth0,bridge=${BRIDGE},ip=${SANDBOX_IP_CIDR},gw=${SANDBOX_GW}"
  NETWORK_MODE="static ${SANDBOX_IP_CIDR} via ${SANDBOX_GW}"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  NETWORK_MODE="dhcp (recommended with a DHCP reservation)"
fi

echo -e "${YW}About to create sandbox CT $SANDBOX_CTID:${CL}
  Network $NETWORK_MODE  bridge $BRIDGE  storage $STORAGE
  ${CORES} cores / ${RAM}MB / ${DISK}GB
  Hermes CT $HERMES_CTID hermes user will SSH in as '$SANDBOX_USER'."
read -rp "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "Aborted."

# ---- 1. template + create CT ------------------------------------------------
info "Ensuring Debian 12 template"
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || die "No debian-12-standard template available."
pveam list local 2>/dev/null | grep -q "$TEMPLATE" || pveam download local "$TEMPLATE" >/dev/null 2>&1
ok "Template: $TEMPLATE"

info "Creating sandbox CT $SANDBOX_CTID"
pct create "$SANDBOX_CTID" "local:vztmpl/$TEMPLATE" \
  --hostname "hermes-sandbox" \
  --cores "$CORES" --memory "$RAM" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --features "nesting=1,keyctl=1" \
  --onboot 1 >/dev/null
pct start "$SANDBOX_CTID" >/dev/null
for _ in $(seq 1 30); do
  SANDBOX_ADDR="$(pct exec "$SANDBOX_CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\r')"
  [ -n "$SANDBOX_ADDR" ] || { sleep 2; continue; }
  pct exec "$SANDBOX_CTID" -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && break
  sleep 2
done
[ -n "$SANDBOX_ADDR" ] || die "Sandbox CT never reported an IPv4 address."
ok "Sandbox CT up at $SANDBOX_ADDR"

# ---- 2. install Docker on the sandbox ----------------------------------------
info "Installing Docker on the sandbox (disposable box — rootful is fine)"
pct exec "$SANDBOX_CTID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl ca-certificates openssh-server fuse-overlayfs >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  systemctl enable --now docker >/dev/null 2>&1 || true
'

info "Verifying Docker storage driver"
if ! pct exec "$SANDBOX_CTID" -- docker info >/dev/null 2>&1; then
  info "overlay2 failed under unprivileged LXC — switching to fuse-overlayfs"
  pct exec "$SANDBOX_CTID" -- bash -lc '
    mkdir -p /etc/docker
    echo "{ \"storage-driver\": \"fuse-overlayfs\" }" > /etc/docker/daemon.json
    systemctl restart docker
  '
fi
pct exec "$SANDBOX_CTID" -- docker run --rm hello-world >/dev/null 2>&1 \
  && ok "Docker working ($(pct exec "$SANDBOX_CTID" -- docker info --format '{{.Driver}}' 2>/dev/null) driver)" \
  || die "Docker smoke test failed — check 'pct exec $SANDBOX_CTID -- journalctl -u docker'."

# ---- 3. low-priv sandbox user (docker-group membership gives container access)
info "Creating '$SANDBOX_USER' user on the sandbox"
pct exec "$SANDBOX_CTID" -- bash -lc "
  id $SANDBOX_USER >/dev/null 2>&1 || useradd -m -s /bin/bash $SANDBOX_USER
  usermod -aG docker $SANDBOX_USER
  install -d -m 700 -o $SANDBOX_USER -g $SANDBOX_USER /home/$SANDBOX_USER/.ssh
"
ok "Sandbox user ready"

# ---- 4. SSH key on CT 100 (hermes) -> sandbox user ---------------------------
info "Generating SSH key for hermes on CT $HERMES_CTID (if absent)"
pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c "
  install -d -m 700 ~/.ssh
  [ -f $KEY_PATH ] || ssh-keygen -t ed25519 -N '' -f $KEY_PATH -C 'hermes-to-sandbox' >/dev/null
"
PUBKEY="$(pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c "cat ${KEY_PATH}.pub")"
[[ -n "$PUBKEY" ]] || die "Could not read hermes public key."

info "Installing hermes key into sandbox authorized_keys"
pct exec "$SANDBOX_CTID" -- su - "$SANDBOX_USER" -c "
  umask 077
  printf '%s\n' '$PUBKEY' >> ~/.ssh/authorized_keys
"

info "Hardening sandbox sshd (key-only, no password auth)"
pct exec "$SANDBOX_CTID" -- bash -lc "
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
"
ok "Key installed, password auth disabled on sandbox"

# ---- 5. known_hosts + ssh config on CT 100 -----------------------------------
info "Configuring hermes ssh client on CT $HERMES_CTID"
pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c "
  ssh-keyscan -H $SANDBOX_ADDR >> ~/.ssh/known_hosts 2>/dev/null
  sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
  if ! grep -q '^Host $SANDBOX_ADDR\$' ~/.ssh/config 2>/dev/null; then
    cat >> ~/.ssh/config <<EOF

Host $SANDBOX_ADDR
    User $SANDBOX_USER
    IdentityFile $KEY_PATH
    IdentitiesOnly yes
EOF
  fi
  chmod 600 ~/.ssh/config ~/.ssh/known_hosts
"
ok "ssh client configured"

# ---- 6. pre-pull the sandbox image -------------------------------------------
info "Pre-pulling $SANDBOX_IMAGE on the sandbox (first-run speed)"
pct exec "$SANDBOX_CTID" -- docker pull "$SANDBOX_IMAGE" >/dev/null 2>&1 \
  && ok "Image cached" || info "Image pull failed (will pull on first use)"

# ---- 6b. install Docker CLI on Hermes CT -------------------------------------
info "Installing Docker CLI on CT $HERMES_CTID (client only; local daemon disabled)"
pct exec "$HERMES_CTID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v docker >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq docker.io >/dev/null
  fi
  systemctl disable --now docker docker.socket containerd >/dev/null 2>&1 || true
'
ok "Docker CLI ready on CT $HERMES_CTID"

# ---- 7. point Hermes at the remote docker ------------------------------------
info "Configuring Hermes to use the remote Docker sandbox"
CONFIG_TMP="$(mktemp)"
cat >"$CONFIG_TMP" <<'PY'
from pathlib import Path
import os

import yaml

cfg = Path.home() / ".hermes" / "config.yaml"
data = yaml.safe_load(cfg.read_text()) or {}
terminal = data.setdefault("terminal", {})
terminal["backend"] = "docker"
terminal["docker_image"] = os.environ["SANDBOX_IMAGE"]
terminal["docker_mount_cwd_to_workspace"] = False
terminal["docker_volumes"] = [os.environ["OUTPUT_MOUNT"]]
terminal["container_persistent"] = True
terminal["persistent_shell"] = True
cfg.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
PY
pct push "$HERMES_CTID" "$CONFIG_TMP" /tmp/configure-hermes-docker.py --perms 755
rm -f "$CONFIG_TMP"

pct exec "$HERMES_CTID" -- bash -lc "
  install -d -m 700 -o $HERMES_USER -g $HERMES_USER '$OUTPUT_DIR'
  su - $HERMES_USER -c \"
    grep -q 'DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR' ~/.bashrc 2>/dev/null \
      || echo 'export DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR' >> ~/.bashrc
    SANDBOX_IMAGE='$SANDBOX_IMAGE' OUTPUT_MOUNT='$OUTPUT_MOUNT' \
      \\\$HOME/.hermes/hermes-agent/venv/bin/python /tmp/configure-hermes-docker.py
  \"
  rm -f /tmp/configure-hermes-docker.py
"
ok "DOCKER_HOST set; Hermes Docker backend configured with $OUTPUT_MOUNT"

# ---- 8. end-to-end verify ----------------------------------------------------
info "End-to-end test: hermes -> ssh -> docker on the sandbox"
if pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c \
   "DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR docker run --rm hello-world"; then
  ok "VERIFIED — hermes can run containers on the sandbox over SSH"
else
  die "End-to-end test failed. Debug from CT $HERMES_CTID as hermes:
     DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR docker run --rm hello-world"
fi

# ---- 9. restart gateway so warnings reflect the new terminal config ----------
info "Restarting Hermes gateway to pick up Docker backend settings"
pct exec "$HERMES_CTID" -- systemctl restart hermes-gateway
sleep 3
pct exec "$HERMES_CTID" -- systemctl --no-pager --lines=12 status hermes-gateway >/dev/null 2>&1 \
  && ok "Gateway restarted" || info "Gateway restarted; check journal if you want detailed status"

# ---- done --------------------------------------------------------------------
cat <<MSG

${GN}Sandbox ready.${CL}
  Sandbox CT  : $SANDBOX_CTID @ $SANDBOX_ADDR  (disposable — 'pct destroy $SANDBOX_CTID' to nuke)
  Backend     : Hermes terminal.backend=docker, DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR
  Output mount: $OUTPUT_MOUNT
  Surface     : CLI only (terminal stays OFF the Telegram toolset)

${YW}Next:${CL}
  1. Test from CLI:  pct enter $HERMES_CTID -> su - hermes -> hermes
     Ask it to run a shell command — it should execute on $SANDBOX_ADDR.
  2. If you used DHCP, reserve $SANDBOX_ADDR for CT $SANDBOX_CTID in UniFi/DHCP
     so DOCKER_HOST stays stable across reboots.
  3. Generated files intended for Telegram/media delivery should be written under
     /output inside the sandbox container so Hermes can map them back to $OUTPUT_DIR.

${YW}Optional hardening:${CL}
  - Put CT 100 and CT $SANDBOX_CTID on a private bridge for a dedicated control plane.
  - Firewall CT $SANDBOX_CTID so it can't reach CT $HERMES_CTID (defence in depth).
  - Run sandbox containers with --network=none if they don't need pip/npm.
  - To nuke and rebuild:  pct stop $SANDBOX_CTID && pct destroy $SANDBOX_CTID
    Then re-run this script.
MSG
