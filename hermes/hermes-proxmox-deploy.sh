#!/usr/bin/env bash
# ============================================================================
# File: ./hermes-proxmox-deploy.sh
# Run ON THE PROXMOX VE HOST as root.
#
# Community-scripts-STYLE deployer for Hermes Agent (Nous Research), configured
# the hardened "PIPS" way we discussed:
#   - Runs as a non-root service user (least privilege)
#   - Skills directory is frozen read-only at runtime (the "locked command list")
#   - Per-platform toolset allow-list on Telegram (no shell / no self-authoring)
#   - PII redaction on, authority bound to a single owner chat
#   - systemd unit tuned for Hermes (ProtectHome OFF, `gateway run` in foreground)
#
# This is *in the style of* the Proxmox VE Helper-Scripts. It is self-contained
# and does NOT source the upstream build.func, because Hermes is not an upstream
# community app. Review before running. No warranty.
# ============================================================================
set -Eeuo pipefail

# --- community-scripts-style colours / message helpers ----------------------
YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}ℹ${CL}"
msg_info()  { echo -e " ${YW}◌${CL} $1"; }
msg_ok()    { echo -e " ${CM} $1"; }
msg_error() { echo -e " ${CROSS} $1"; }
trap 'msg_error "Failed at line $LINENO. Aborting."' ERR

header_info() {
clear
cat <<"EOF"
   __ __                          _                    __
  / // /__ ______ _  ___ ___    / |  ___ ____ ___  ___/ /_
 / _  / -_) __/  ' \/ -_|_-<   / /| |/ _ `/ -_) _ \/ _  / __|
/_//_/\__/_/ /_/_/_/\__/___/  /_/ |_|\_, /\__/_//_/\_,_/\__/
                                    /___/   Proxmox LXC (PIPS-hardened)
EOF
}

# --- pre-flight -------------------------------------------------------------
header_info
[ "$(id -u)" -eq 0 ] || { msg_error "Run as root on the Proxmox host."; exit 1; }
command -v pct >/dev/null 2>&1 || { msg_error "pct not found — run this on a Proxmox VE host."; exit 1; }

# --- settings (Enter accepts the default) -----------------------------------
NEXTID="$(pvesh get /cluster/nextid 2>/dev/null || echo 100)"
read -rp "${INFO} Container ID            [${NEXTID}]: " CTID;     CTID="${CTID:-$NEXTID}"
read -rp "${INFO} Hostname               [simba]: " HOSTNAME;     HOSTNAME="${HOSTNAME:-simba}"
read -rp "${INFO} Disk size (GB)         [8]: " DISK;             DISK="${DISK:-8}"
read -rp "${INFO} CPU cores              [2]: " CPU;              CPU="${CPU:-2}"
read -rp "${INFO} RAM (MB)               [2048]: " RAM;           RAM="${RAM:-2048}"
read -rp "${INFO} Bridge                 [vmbr0]: " BRIDGE;       BRIDGE="${BRIDGE:-vmbr0}"
read -rp "${INFO} Rootfs storage         [local-lvm]: " STORAGE;  STORAGE="${STORAGE:-local-lvm}"
read -rp "${INFO} Template storage       [local]: " TPLSTORE;     TPLSTORE="${TPLSTORE:-local}"

echo
msg_info "Secrets (kept out of process args; pushed via a 0600 file and shredded after)"
read -rp "${INFO} Telegram bot token              : " BOT_TOKEN
read -rp "${INFO} Owner Telegram chat id          : " HOME_CHAT_ID
read -rp "${INFO} Ollama base URL                 [http://10.1.1.194:11434/v1]: " OLLAMA_BASE_URL
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://10.1.1.194:11434/v1}"
read -rp "${INFO} Ollama model name               [gemma4:12b]: " OLLAMA_MODEL
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma4:12b}"
read -rp "${INFO} Tavily API key (tvly-..., optional): " TAVILY_API_KEY
[ -n "$BOT_TOKEN" ] || { msg_error "Bot token is required."; exit 1; }

# --- template ---------------------------------------------------------------
msg_info "Ensuring a Debian 12 LXC template is available"
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || { msg_error "No debian-12-standard template found in 'pveam available'."; exit 1; }
if ! pveam list "$TPLSTORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  pveam download "$TPLSTORE" "$TEMPLATE" >/dev/null
fi
TPL_VOL="${TPLSTORE}:vztmpl/${TEMPLATE}"
msg_ok "Template ready: ${TEMPLATE}"

# --- create the container (unprivileged, no nesting — web researcher) -------
msg_info "Creating unprivileged LXC ${CTID} (${HOSTNAME})"
pct create "$CTID" "$TPL_VOL" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" --memory "$RAM" --swap 512 \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --ostype debian \
  --unprivileged 1 \
  --features keyctl=1 \
  --onboot 1 \
  --description "Hermes Agent (Simba) — PIPS-hardened. Deployed $(date -Is)" >/dev/null
msg_ok "Container ${CTID} created"

msg_info "Starting container and waiting for network"
pct start "$CTID" >/dev/null
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 && break
  sleep 2
done
msg_ok "Network is up"

# --- push secrets (0600) and the in-container installer ---------------------
SECRETS_TMP="$(mktemp)"; chmod 600 "$SECRETS_TMP"
cat >"$SECRETS_TMP" <<EOF
BOT_TOKEN='${BOT_TOKEN}'
HOME_CHAT_ID='${HOME_CHAT_ID}'
OLLAMA_BASE_URL='${OLLAMA_BASE_URL}'
OLLAMA_MODEL='${OLLAMA_MODEL}'
TAVILY_API_KEY='${TAVILY_API_KEY}'
EOF
pct push "$CTID" "$SECRETS_TMP" /root/.hermes-secrets --perms 600
shred -u "$SECRETS_TMP"
unset BOT_TOKEN HOME_CHAT_ID OLLAMA_BASE_URL OLLAMA_MODEL TAVILY_API_KEY

INSTALL_TMP="$(mktemp)"
cat >"$INSTALL_TMP" <<'INSTALL'
#!/usr/bin/env bash
# Runs INSIDE the container. Provisions and hardens Hermes Agent.
set -Eeuo pipefail
source /root/.hermes-secrets

SVCUSER="hermes"
HHOME="/home/${SVCUSER}/.hermes"

echo "[1/8] System dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git ca-certificates ripgrep ffmpeg sudo procps >/dev/null

echo "[2/8] Service user (non-root = the heart of the PIPS posture)"
id "$SVCUSER" >/dev/null 2>&1 || adduser --disabled-password --gecos "Hermes Agent" "$SVCUSER" >/dev/null

echo "[3/8] Temporary sudo for the installer (apt: node/ffmpeg/etc.)"
echo "${SVCUSER} ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/hermes-install
chmod 440 /etc/sudoers.d/hermes-install

echo "[4/8] Installing Hermes Agent as ${SVCUSER} (uv + venv in userspace)"
runuser -l "$SVCUSER" -c 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash'

echo "[5/8] Revoking installer sudo (agent runs unprivileged from here on)"
rm -f /etc/sudoers.d/hermes-install

# Build the skills manifest/index now, while the directory is still writable,
# so freezing it read-only next step doesn't trigger a manifest write on boot.
runuser -l "$SVCUSER" -c 'hermes skills list >/dev/null 2>&1 || true'

echo "[6/8] Writing hardened config + secrets"
runuser -l "$SVCUSER" -c "install -d -m 700 '${HHOME}'"

# --- /home/hermes/.hermes/.env (secrets, 0600) ---
umask 077
printf 'OPENAI_BASE_URL=%s\nOPENAI_API_KEY=ollama\nTAVILY_API_KEY=%s\nTELEGRAM_BOT_TOKEN=%s\n' \
  "$OLLAMA_BASE_URL" "$TAVILY_API_KEY" "$BOT_TOKEN" >"${HHOME}/.env"
chown "${SVCUSER}:${SVCUSER}" "${HHOME}/.env"; chmod 600 "${HHOME}/.env"

# --- /home/hermes/.hermes/config.yaml (hardened) ---
cat >"${HHOME}/config.yaml" <<YAML
# /home/hermes/.hermes/config.yaml
# NOTE: provider/model key names move between Hermes versions. If the gateway
# ignores these, run \`runuser -l hermes -c 'hermes setup'\` once and keep the
# blocks below as the hardening overlay. Verify with \`hermes config\`.
model:
  default: ${OLLAMA_MODEL}
  provider: openai-compatible
  base_url: ${OLLAMA_BASE_URL}

# --- PIPS: Telegram is a read-only researcher --------------------------------
# Omitting 'skills' removes skill_manage  -> the agent cannot author/alter its
#   own instruction files (the runtime half of the "locked command list").
# Omitting terminal/code_execution/file/delegation/homeassistant/cronjob shrinks
#   blast radius so an injected web result can't reach a shell or your data.
platform_toolsets:
  telegram:
    - web
    - browser
    - memory
    - todo
    - session_search
    - clarify

# --- Authority binding: only this chat is the principal ----------------------
gateway:
  platforms:
    telegram:
      home_chat_id: "${HOME_CHAT_ID}"
      gateway_restart_notification: false

# --- Strip PII before it reaches the LLM (supported on Telegram) -------------
privacy:
  redact_pii: true
YAML
chown "${SVCUSER}:${SVCUSER}" "${HHOME}/config.yaml"; chmod 600 "${HHOME}/config.yaml"

echo "[7/8] Freezing the skills directory read-only (root-owned 0555/0444)"
# A non-root agent cannot write into a root-owned, non-writable tree. Combined
# with the toolset omission above, this is the immutable "command list": the
# agent reads its skills but can never add to or change them at runtime.
SKILLS="${HHOME}/skills"
if [ -d "$SKILLS" ]; then
  chown -R root:root "$SKILLS"
  find "$SKILLS" -type d -exec chmod 0555 {} +
  find "$SKILLS" -type f -exec chmod 0444 {} +
fi

echo "[8/8] systemd unit"
cat >/etc/systemd/system/hermes-gateway.service <<UNIT
# /etc/systemd/system/hermes-gateway.service
[Unit]
Description=Hermes Agent Gateway (Simba)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVCUSER}
Group=${SVCUSER}
Environment=HOME=/home/${SVCUSER}
WorkingDirectory=/home/${SVCUSER}
# Hermes writes to ~/.hermes — ProtectHome MUST be off or every write fails.
ProtectHome=false
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/${SVCUSER}/.hermes
# Belt-and-braces over the DAC freeze above:
ReadOnlyPaths=/home/${SVCUSER}/.hermes/skills
# 'gateway run' stays in the foreground for systemd to supervise.
# ('gateway start' self-daemonises — wrong under systemd.)
ExecStart=/usr/bin/bash -lc 'exec hermes gateway run'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hermes-gateway.service >/dev/null 2>&1 || true
sleep 3
systemctl --no-pager --lines=15 status hermes-gateway.service || true
INSTALL

pct push "$CTID" "$INSTALL_TMP" /root/hermes-install.sh --perms 700
rm -f "$INSTALL_TMP"

msg_info "Provisioning and hardening Hermes inside the container"
pct exec "$CTID" -- bash /root/hermes-install.sh

# --- cleanup secrets / installer from the container -------------------------
pct exec "$CTID" -- shred -u /root/.hermes-secrets /root/hermes-install.sh 2>/dev/null || \
  pct exec "$CTID" -- rm -f /root/.hermes-secrets /root/hermes-install.sh

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo
msg_ok "Done."
echo -e "${INFO} CTID ${CTID} (${HOSTNAME})  IP ${IP:-<dhcp pending>}"
echo -e "${INFO} Console:    ${BL}pct enter ${CTID}${CL}"
echo -e "${INFO} Logs:       ${BL}pct exec ${CTID} -- journalctl -u hermes-gateway -f${CL}"
echo -e "${INFO} Edit skills (you only — agent can't): ${BL}pct exec ${CTID} -- chmod -R u+w /home/hermes/.hermes/skills${CL}  (then re-freeze step 7)"
cat <<'NOTES'

 Verify after first boot:
   • Message Simba from your owner chat — confirm it replies.
   • `journalctl -u hermes-gateway`: if you see a *provider/model* error, run
     `runuser -l hermes -c 'hermes setup'` once, then re-add the hardening blocks.
   • Confirm the Tavily key/env name matches your Hermes version (web provider
     wiring varies; this script sets TAVILY_API_KEY).
   • If ProtectSystem=strict trips an unexpected write, relax it to `full`.
   • Want shell/code tools later? Add `terminal`/`code_execution` to
     platform_toolsets AND switch the terminal backend to Docker (set CT
     feature nesting=1) — never give the gateway a *local* shell on Telegram.
NOTES
