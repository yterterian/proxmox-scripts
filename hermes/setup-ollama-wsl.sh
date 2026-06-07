#!/usr/bin/env bash
# =============================================================================
# File: hermes-proxmox/setup-ollama-wsl.sh
#
# Run this INSIDE your WSL2 Ubuntu distro (the gaming PC with the RTX 5080).
# It installs Ollama, configures it to stay resident and reachable on the LAN,
# pins a >=64K context for Hermes, pulls gemma4:12b, and verifies GPU placement.
#
#   bash setup-ollama-wsl.sh
#
# Windows-side steps (mirrored networking, firewall, boot task, sleep) CANNOT
# be done from inside WSL — see the checklist printed at the end.
# =============================================================================
set -euo pipefail

GN=$'\033[1;92m'; YW=$'\033[33m'; RD=$'\033[01;31m'; CL=$'\033[m'
info(){ echo -e " ${YW}»${CL} $1"; }
ok(){ echo -e " ${GN}✓${CL} $1"; }
die(){ echo -e " ${RD}✗ $1${CL}"; exit 1; }

# --- 1. systemd must be the init system for an enable-able service -----------
if [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
  info "systemd is not running in this WSL distro. Enabling it..."
  sudo tee /etc/wsl.conf >/dev/null <<'CONF'
[boot]
systemd=true
CONF
  cat <<'MSG'

  /etc/wsl.conf written. Now, from a WINDOWS PowerShell/CMD prompt run:

      wsl --shutdown

  Wait ~10 seconds, reopen WSL, and re-run this script.
MSG
  exit 0
fi
ok "systemd is active"

# --- 2. GPU visible inside WSL? ---------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  ok "NVIDIA GPU visible to WSL ($(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1))"
else
  die "nvidia-smi failed. Update the NVIDIA *Windows* driver (it provides the WSL CUDA stub). Do NOT install a Linux GPU driver inside WSL."
fi

# --- 3. Install Ollama (idempotent) -----------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
  info "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
ok "Ollama present ($(ollama --version 2>/dev/null | head -n1))"

# --- 4. systemd override: persistence + reachability + 64K context ----------
# Environment rationale:
#   OLLAMA_HOST=0.0.0.0:11434  -> listen on all interfaces (reachable from CT)
#   OLLAMA_KEEP_ALIVE=-1       -> never unload the model between Hermes turns
#   OLLAMA_CONTEXT_LENGTH=65536-> meet Hermes' >=64K floor
#   OLLAMA_FLASH_ATTENTION=1   -> needed to enable a quantised KV cache
#   OLLAMA_KV_CACHE_TYPE=q8_0  -> ~halves KV VRAM so 64K ctx fits 16GB alongside
#                                 a ~10GB model (negligible quality impact)
info "Writing systemd override..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'OVR'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_CONTEXT_LENGTH=65536"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
OVR
sudo systemctl daemon-reload
sudo systemctl enable ollama >/dev/null 2>&1 || true
sudo systemctl restart ollama
ok "Ollama service configured, enabled, and restarted"

# --- 5. Pull the model -------------------------------------------------------
info "Pulling gemma4:12b (GGUF — not the -mlx tag)..."
ollama pull gemma4:12b
ok "Model pulled"

# --- 6. Verify GPU placement (the real test) --------------------------------
info "Warming the model and checking placement..."
ollama run gemma4:12b "ok" >/dev/null 2>&1 || true
echo
ollama ps || true
echo
cat <<MSG
${YW}Read the PROCESSOR column above:${CL}
  100% GPU            -> good, you're done on the WSL side.
  a CPU/GPU split     -> the 64K KV cache tipped you over 16GB. Lower
                         OLLAMA_CONTEXT_LENGTH toward 65536 if you raised it,
                         keep q8_0 KV, or trim context. Re-run after editing
                         the override + 'sudo systemctl restart ollama'.

${YW}=== WINDOWS-SIDE STEPS (cannot be scripted from inside WSL) ===${CL}

1. Reachability — mirrored networking (Win11 22H2+). Create/edit
   %UserProfile%\\.wslconfig  with:
       [wsl2]
       networkingMode=mirrored
   then 'wsl --shutdown' from PowerShell and reopen.
   (Win10 fallback: netsh portproxy v4tov4 from host:11434 -> WSL IP:11434,
    but the WSL IP changes on restart — mirrored mode avoids that churn.)

2. Firewall — allow inbound 11434 (PowerShell as admin):
       New-NetFirewallRule -DisplayName "Ollama 11434" -Direction Inbound \\
         -Protocol TCP -LocalPort 11434 -Action Allow

3. Auto-start the VM at boot — Task Scheduler task, trigger "At startup",
   action: program  wsl.exe   arguments  -d Ubuntu --exec /bin/true
   (booting the distro starts systemd; the ollama service then keeps the VM
    alive, defeating WSL's idle shutdown.)

4. Never sleep (PowerShell as admin):
       powercfg /change standby-timeout-ac 0
       powercfg /change hibernate-timeout-ac 0

5. Point Hermes at this box. In install-hermes-ct.sh choose 'ollama' and set:
       Base URL : http://<this-PC-LAN-IP>:11434/v1
       Model    : gemma4:12b
   Find the LAN IP with 'ipconfig' (Windows) — NOT the 172.x WSL address.

${YW}Quick end-to-end test from the Proxmox CT:${CL}
   curl http://<this-PC-LAN-IP>:11434/api/tags
MSG
