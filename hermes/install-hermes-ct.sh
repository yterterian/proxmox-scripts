#!/usr/bin/env bash
# =============================================================================
# File: hermes-proxmox/install-hermes-ct.sh
#
# LEGACY PATH: this script overlaps heavily with hermes-proxmox-deploy.sh.
# Keep it only for its older multi-provider/manual-bootstrap flow. The
# maintained Proxmox deploy path is hermes-proxmox-deploy.sh.
#
# Community-style Proxmox VE deployment for Hermes Agent (Nous Research).
# Run this ON THE PROXMOX HOST as root. It creates an unprivileged Debian 12
# LXC, installs Hermes under a dedicated least-privilege user, drops in a
# hardened config, and registers a systemd service for the messaging gateway.
#
#   bash install-hermes-ct.sh
#
# Hardening baked in:
#   - dedicated 'hermes' user (no root, file toolset can't read root secrets)
#   - skill_manage disabled  -> agent cannot rewrite its own instruction set
#   - privacy.redact_pii: true
#   - minimal Telegram toolset (web research bot; no shell by default)
#   - secrets chmod 600
#   - systemd: ProtectHome OFF (known Hermes blocker) + scoped ReadWritePaths
#
# NOTE: config key names and CLI verbs shift between Hermes releases
# (v0.15-era shown). After install, validate with `hermes doctor` and
# `hermes config`. This script is a starting point, not a frozen spec.
# =============================================================================
set -euo pipefail

# ---- pretty output (community-scripts idiom) -------------------------------
RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; CL=$'\033[m'
BFR="\\r\\033[K"; HOLD=" "; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
msg_info()  { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_err()   { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

header() {
cat <<"EOF"
   __ __                          ___                 __
  / // /__ ______ _  ___ ___    / _ | ___ ____ ___  / /_
 / _  / -_) __/  ' \/ -_|_-<   / __ |/ _ `/ -_) _ \/ __/
/_//_/\__/_/ /_/_/_/\__/___/  /_/ |_|\_, /\__/_//_/\__/
                                    /___/   Proxmox CT
EOF
}

# ---- preflight --------------------------------------------------------------
[[ $EUID -eq 0 ]] || { msg_err "Run as root on the Proxmox host."; exit 1; }
command -v pct >/dev/null 2>&1 || { msg_err "pct not found — this must run on a Proxmox VE host."; exit 1; }
command -v whiptail >/dev/null 2>&1 || { msg_err "whiptail not found (apt install whiptail)."; exit 1; }

clear; header
echo -e "${YW}WARNING:${CL} install-hermes-ct.sh is a legacy installer."
echo -e "         Prefer ${GN}hermes-proxmox-deploy.sh${CL} for the maintained path."
echo

# ---- settings ---------------------------------------------------------------
NEXTID="$(pvesh get /cluster/nextid 2>/dev/null || echo 100)"
CTID="$NEXTID"
HOSTNAME="hermes"
DISK_GB="8"
RAM_MB="2048"
CORES="2"
BRIDGE="vmbr0"
STORAGE="local-lvm"
UNPRIVILEGED="1"
CT_PASS="$(openssl rand -base64 18)"   # root pw inside the CT; change later if you like

if whiptail --title "Hermes CT" --yesno "Use default settings?\n\nCTID: $CTID\nHostname: $HOSTNAME\nDisk: ${DISK_GB}G  RAM: ${RAM_MB}M  Cores: $CORES\nBridge: $BRIDGE  Storage: $STORAGE\nUnprivileged: yes" 16 60; then
  msg_ok "Using defaults"
else
  CTID="$(whiptail --inputbox "Container ID" 8 60 "$CTID" --title "CTID" 3>&1 1>&2 2>&3)"
  HOSTNAME="$(whiptail --inputbox "Hostname" 8 60 "$HOSTNAME" --title "Hostname" 3>&1 1>&2 2>&3)"
  CORES="$(whiptail --inputbox "vCPU cores" 8 60 "$CORES" --title "Cores" 3>&1 1>&2 2>&3)"
  RAM_MB="$(whiptail --inputbox "RAM (MB)" 8 60 "$RAM_MB" --title "RAM" 3>&1 1>&2 2>&3)"
  DISK_GB="$(whiptail --inputbox "Disk (GB)" 8 60 "$DISK_GB" --title "Disk" 3>&1 1>&2 2>&3)"
  BRIDGE="$(whiptail --inputbox "Network bridge" 8 60 "$BRIDGE" --title "Bridge" 3>&1 1>&2 2>&3)"
  STORAGE="$(whiptail --inputbox "Storage pool" 8 60 "$STORAGE" --title "Storage" 3>&1 1>&2 2>&3)"
fi

# ---- provider choice --------------------------------------------------------
PROVIDER="$(whiptail --title "LLM Provider" --menu "How should the gateway talk to a model?" 16 72 4 \
  "anthropic" "Claude (Haiku 4.5) via Anthropic API key  [recommended 24/7]" \
  "openai"    "OpenAI GPT-5.4-mini via API key  [best cost/quality on OpenAI]" \
  "ollama"    "Local Ollama endpoint (e.g. your gaming PC)" \
  "later"     "Skip — I'll run 'hermes model' myself" \
  3>&1 1>&2 2>&3)"

ANTHROPIC_KEY=""
OPENAI_KEY=""
OPENAI_MODEL=""
OLLAMA_BASE=""
OLLAMA_MODEL=""
case "$PROVIDER" in
  anthropic)
    ANTHROPIC_KEY="$(whiptail --passwordbox "Anthropic API key (sk-ant-...)" 8 70 --title "Anthropic" 3>&1 1>&2 2>&3)"
    ;;
  openai)
    OPENAI_KEY="$(whiptail --passwordbox "OpenAI API key (sk-...)" 8 70 --title "OpenAI" 3>&1 1>&2 2>&3)"
    OPENAI_MODEL="$(whiptail --inputbox "Model name (>=64K ctx; gpt-5.4 for harder tasks)" 8 70 "gpt-5.4-mini" --title "OpenAI" 3>&1 1>&2 2>&3)"
    ;;
  ollama)
    OLLAMA_BASE="$(whiptail --inputbox "Ollama OpenAI-compatible base URL\n(e.g. http://10.1.1.50:11434/v1)" 9 70 "http://10.1.1.50:11434/v1" --title "Ollama" 3>&1 1>&2 2>&3)"
    # gemma4:12b is the target fit for a 16GB GPU (128K ctx, native tool-calling).
    # NOTE: if 12b isn't published to Ollama yet, gemma4:e4b (9.6GB) is the
    # interim that fits 16GB; 26b (18GB) and 31b (20GB) will NOT fit a 5080.
    OLLAMA_MODEL="$(whiptail --inputbox "Model name (>=64K ctx; must fit your VRAM)\n12b targets 16GB; fall back to gemma4:e4b if 12b not on Ollama yet" 9 72 "gemma4:12b" --title "Ollama" 3>&1 1>&2 2>&3)"
    ;;
esac

# ---- template ---------------------------------------------------------------
msg_info "Ensuring Debian 12 template is available"
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || { msg_err "No debian-12-standard template found in 'pveam available'."; exit 1; }
if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
  pveam download local "$TEMPLATE" >/dev/null 2>&1
fi
msg_ok "Template ready: $TEMPLATE"

# ---- create container -------------------------------------------------------
msg_info "Creating CT $CTID ($HOSTNAME)"
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" --memory "$RAM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged "$UNPRIVILEGED" \
  --features "nesting=1,keyctl=1" \
  --password "$CT_PASS" \
  --onboot 1 >/dev/null
msg_ok "Container created"

msg_info "Starting container"
pct start "$CTID" >/dev/null
# wait for network
for _ in $(seq 1 30); do
  pct exec "$CTID" -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && break
  sleep 2
done
msg_ok "Container up"

# ---- in-container provisioning ---------------------------------------------
# Everything below runs INSIDE the CT via heredoc. Paths are container paths.
HERMES_HOME="/home/hermes/.hermes"

msg_info "Installing base packages"
pct exec "$CTID" -- bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates ripgrep ffmpeg jq >/dev/null
' >/dev/null
msg_ok "Base packages installed"

msg_info "Creating least-privilege hermes user"
pct exec "$CTID" -- bash -lc '
  id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
' >/dev/null
msg_ok "User 'hermes' ready"

msg_info "Installing Hermes Agent (official installer, --skip-setup)"
# Runs as the hermes user; installer pulls uv + Python 3.11 and lands in ~/.hermes.
pct exec "$CTID" -- su - hermes -c '
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --skip-setup
' >/dev/null 2>&1 || { msg_err "Hermes installer failed — check 'pct exec $CTID -- su - hermes -c \"hermes doctor\"'"; exit 1; }
msg_ok "Hermes installed"

# ---- hardened config --------------------------------------------------------
# File (in container): /home/hermes/.hermes/config.yaml
msg_info "Writing hardened config.yaml"
pct exec "$CTID" -- su - hermes -c "mkdir -p '$HERMES_HOME/skills' '$HERMES_HOME/logs'"
pct exec "$CTID" -- su - hermes -c "cat > '$HERMES_HOME/config.yaml' <<'YAML'
# ~/.hermes/config.yaml  (hardened starter — validate with: hermes config)
privacy:
  redact_pii: true            # strip PII from LLM context (Telegram supported)

tools:
  disabled:
    - skill_manage            # agent cannot author/mutate its own skills at runtime
    - terminal                # web-research bot needs no shell
    - code_execution          # drop if you do not run code from chat
    - delegation
    - homeassistant

display:
  platforms:
    telegram:
      tool_progress: off

gateway:
  platforms:
    telegram:
      # Set this to YOUR Telegram chat id so only you hold authority.
      # Find it after 'hermes gateway setup' or via @userinfobot.
      home_chat_id: \"CHANGE_ME\"
      gateway_restart_notification: false
YAML"
msg_ok "config.yaml written"

# ---- provider credentials ---------------------------------------------------
# File (in container): /home/hermes/.hermes/.env  (chmod 600)
msg_info "Configuring provider"
pct exec "$CTID" -- su - hermes -c "touch '$HERMES_HOME/.env' && chmod 600 '$HERMES_HOME/.env'"
case "$PROVIDER" in
  anthropic)
    pct exec "$CTID" -- su - hermes -c "printf 'ANTHROPIC_API_KEY=%s\nTELEGRAM_ALLOWED_USERS=\n' '$ANTHROPIC_KEY' >> '$HERMES_HOME/.env'"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.provider anthropic >/dev/null 2>&1 || true"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.name claude-haiku-4-5 >/dev/null 2>&1 || true"
    ;;
  openai)
    # GPT-5.4-mini: best cost/quality on OpenAI for an agent brain ($0.75/$4.50 per MTok,
    # ~June 2026). Clears Hermes' 64K context floor comfortably. Step up to gpt-5.4 for
    # harder reasoning turns via 'hermes model' later.
    pct exec "$CTID" -- su - hermes -c "printf 'OPENAI_API_KEY=%s\nTELEGRAM_ALLOWED_USERS=\n' '$OPENAI_KEY' >> '$HERMES_HOME/.env'"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.provider openai >/dev/null 2>&1 || true"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.name '$OPENAI_MODEL' >/dev/null 2>&1 || true"
    ;;
  ollama)
    # Ollama is OpenAI-compatible at /v1. ON THE OLLAMA HOST (e.g. gaming PC):
    #   1. Keep the model resident:   export OLLAMA_KEEP_ALIVE=-1
    #   2. Pull a model that fits VRAM *with* a 64K KV cache. On a 16GB 5080:
    #        gemma4:12b  -> target fit (128K ctx, native tool-calling) when published
    #        gemma4:e4b  -> 9.6GB, fits today (weaker tool-use: Tau2 ~42%)
    #        gemma4:26b/31b -> 18-20GB, will NOT fit 16GB
    #   3. Set context >=64K:  num_ctx 65536  (Modelfile or OLLAMA_CONTEXT_LENGTH)
    #   4. Gemma 4 sampling: temperature 1.0, top_p 0.95, top_k 64
    #   Quick local smoke test (Ollama has a Hermes launcher):
    #        ollama launch hermes --model gemma4
    pct exec "$CTID" -- su - hermes -c "printf 'OPENAI_BASE_URL=%s\nOPENAI_API_KEY=ollama\nTELEGRAM_ALLOWED_USERS=\n' '$OLLAMA_BASE' >> '$HERMES_HOME/.env'"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.provider custom >/dev/null 2>&1 || true"
    pct exec "$CTID" -- su - hermes -c "hermes config set model.name '$OLLAMA_MODEL' >/dev/null 2>&1 || true"
    ;;
  later)
    msg_ok "Skipping provider — run 'hermes model' inside the CT later"
    ;;
esac
[[ "$PROVIDER" != "later" ]] && msg_ok "Provider configured ($PROVIDER)"

# ---- systemd service --------------------------------------------------------
# File (in container): /etc/systemd/system/hermes-gateway.service
# IMPORTANT: ProtectHome is OFF on purpose. Setting it true blocks Hermes
# writing to ~/.hermes (sessions, memory, skills) — a known failure mode.
msg_info "Installing systemd service"
pct exec "$CTID" -- bash -lc "cat > /etc/systemd/system/hermes-gateway.service <<'UNIT'
[Unit]
Description=Hermes Agent messaging gateway (Simba)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Environment=HOME=/home/hermes
Environment=PATH=/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=/home/hermes
ExecStart=/usr/bin/env bash -lc 'hermes gateway run'
Restart=on-failure
RestartSec=5

# --- sandboxing (least privilege without breaking Hermes' writes) ---
NoNewPrivileges=true
ProtectHome=false
ProtectSystem=strict
ReadWritePaths=/home/hermes/.hermes
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT"
pct exec "$CTID" -- systemctl daemon-reload
msg_ok "Service installed (not started yet — Telegram token needed first)"

# ---- done -------------------------------------------------------------------
CT_IP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || echo '<dhcp>')"
clear; header
echo -e "${GN}Hermes CT $CTID deployed.${CL}\n"
echo -e "Container IP : ${YW}${CT_IP}${CL}"
echo -e "CT root pw   : ${YW}${CT_PASS}${CL}  (change with 'passwd' inside the CT)\n"
echo -e "${YW}Next steps (interactive — needs your Telegram bot token):${CL}"
echo    "  1. pct enter $CTID"
echo    "  2. su - hermes"
echo    "  3. hermes gateway setup        # paste BotFather token, name it 'Simba'"
echo    "  4. printf 'TELEGRAM_ALLOWED_USERS=<your-id>\n' >> ~/.hermes/.env"
echo    "  5. hermes config set gateway.platforms.telegram.home_chat_id <your-id>"
echo    "  6. hermes doctor               # sanity check"
echo    "  7. exit; systemctl enable --now hermes-gateway"
echo    "  8. systemctl status hermes-gateway  /  journalctl -u hermes-gateway -f"
echo
echo -e "${YW}Optional Layer-1 lockdown (run ON THE HOST after step 5):${CL}"
echo    "  # Make the skills dir read-only to the agent (PIPS-style immutable"
echo    "  # instruction set). You edit skills host-side; the agent never can."
echo    "  # Unprivileged CT caveat: the host source dir must be owned by the"
echo    "  # SHIFTED uid (100000 + hermes_uid). Verify before trusting it:"
echo    "  #   HOST_SRC=/tank/hermes-skills"
echo    "  #   mkdir -p \$HOST_SRC && chown 101000:101000 \$HOST_SRC"
echo    "  #   pct set $CTID -mp0 \$HOST_SRC,mp=/home/hermes/.hermes/skills,ro=1"
echo    "  #   pct reboot $CTID"
echo
