#!/usr/bin/env bash
# =============================================================================
# File: hermes/setup-sandbox-ct.sh
#
# Disposable Docker sandbox for Hermes' terminal/code-execution.
# Run on the PROXMOX HOST as root.
#
# Architecture:
#   CT 100 (Hermes/Simba, holds secrets)  --ssh-->  CT 105 (sandbox, runs Docker)
#   Hermes terminal.backend=docker + DOCKER_HOST=ssh://sandbox@10.1.1.120
#   => every agent shell spawns an ephemeral container ON 105, never on 100.
#   => secrets stay on 100; blast radius is a box you can `pct destroy`.
#
# Keep terminal CLI-ONLY (already removed from the Telegram toolset).
# =============================================================================
set -euo pipefail

# ---- settings ---------------------------------------------------------------
SANDBOX_CTID="105"
HERMES_CTID="100"
SANDBOX_IP="10.1.1.120/24"
SANDBOX_GW="10.1.1.1"
SANDBOX_ADDR="10.1.1.120"
BRIDGE="vmbr0"
STORAGE="local-lvm"
CORES="2"; RAM="2048"; DISK="30"
SANDBOX_USER="sandbox"
SANDBOX_IMAGE="nikolaik/python-nodejs:python3.13-nodejs24"
HERMES_USER="hermes"
KEY_PATH="/home/hermes/.ssh/sandbox_docker"

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

echo -e "${YW}About to create sandbox CT $SANDBOX_CTID:${CL}
  IP $SANDBOX_IP  GW $SANDBOX_GW  bridge $BRIDGE  storage $STORAGE
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
  --net0 "name=eth0,bridge=${BRIDGE},ip=${SANDBOX_IP},gw=${SANDBOX_GW}" \
  --unprivileged 1 \
  --features "nesting=1,keyctl=1" \
  --onboot 1 >/dev/null
pct start "$SANDBOX_CTID" >/dev/null
for _ in $(seq 1 30); do pct exec "$SANDBOX_CTID" -- ping -c1 -W1 "$SANDBOX_GW" >/dev/null 2>&1 && break; sleep 2; done
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

# ---- 7. point Hermes at the remote docker ------------------------------------
info "Setting DOCKER_HOST for hermes (CLI surface only)"
pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c "
  grep -q 'DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR' ~/.bashrc 2>/dev/null \
    || echo 'export DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR' >> ~/.bashrc
  hermes config set terminal.backend docker >/dev/null 2>&1 || true
"
ok "DOCKER_HOST set; terminal.backend=docker"

# ---- 8. end-to-end verify ----------------------------------------------------
info "End-to-end test: hermes -> ssh -> docker on the sandbox"
if pct exec "$HERMES_CTID" -- su - "$HERMES_USER" -c \
   "DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR docker run --rm hello-world >/dev/null 2>&1"; then
  ok "VERIFIED — hermes can run containers on the sandbox over SSH"
else
  die "End-to-end test failed. Debug from CT $HERMES_CTID as hermes:
     DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR docker run --rm hello-world"
fi

# ---- done --------------------------------------------------------------------
cat <<MSG

${GN}Sandbox ready.${CL}
  Sandbox CT  : $SANDBOX_CTID @ $SANDBOX_ADDR  (disposable — 'pct destroy $SANDBOX_CTID' to nuke)
  Backend     : Hermes terminal.backend=docker, DOCKER_HOST=ssh://$SANDBOX_USER@$SANDBOX_ADDR
  Surface     : CLI only (terminal stays OFF the Telegram toolset)

${YW}Next:${CL}
  1. Restart the gateway:  pct exec $HERMES_CTID -- systemctl restart hermes-gateway
  2. Test from CLI:  pct enter $HERMES_CTID -> su - hermes -> hermes
     Ask it to run a shell command — it should execute on $SANDBOX_ADDR.

${YW}Optional hardening:${CL}
  - Firewall CT $SANDBOX_CTID so it can't reach CT $HERMES_CTID (defence in depth).
  - Run sandbox containers with --network=none if they don't need pip/npm.
  - To nuke and rebuild:  pct stop $SANDBOX_CTID && pct destroy $SANDBOX_CTID
    Then re-run this script.
MSG
