# Actual Budget - Optimised Proxmox LXC Scripts

These scripts install [Actual Budget](https://actualbudget.org/) in a Proxmox LXC container with a custom MOTD banner that displays the IP address and port on console login.

## What You Get

When you open the Proxmox console for the container, you'll see:

```
Actual Budget LXC Container
    🌐   Provided by: community-scripts ORG | GitHub: https://github.com/community-scripts/ProxmoxVE
    🖥️   OS: Debian GNU/Linux - Version: 13
    🏠   Hostname: actualbudget
    💡   IP Address: 10.1.1.46

    📊   Service Status: ● Running
    📦   Version: 25.5.0
    🌍   Web UI: http://10.1.1.46:5006

    💡   Run 'update' to check for new versions
```

## Installation Options

### Option 1: Standalone Script (Recommended)

This is the simplest approach - create a container manually, then run the standalone script inside it.

1. **Create an LXC container in Proxmox:**
   - Template: Debian 12 or 13 (Bookworm or Trixie)
   - Disk: 4GB minimum
   - RAM: 2GB recommended
   - CPU: 2 cores recommended
   - Network: DHCP or static IP

2. **Start the container and open console**

3. **Run the standalone installer:**
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR-REPO/actualbudget-standalone.sh)
   ```

   Or download and run:
   ```bash
   curl -fsSL -o install.sh https://raw.githubusercontent.com/YOUR-REPO/actualbudget-standalone.sh
   chmod +x install.sh
   ./install.sh
   ```

### Option 2: Community-Scripts Style (Advanced)

If you want to use the same framework as the official community-scripts project:

1. **Host the files** on a web server or GitHub repo:
   - `ct/actualbudget.sh` - Container creation script
   - `install/actualbudget-install.sh` - In-container installation script

2. **Run from Proxmox host shell:**
   ```bash
   bash -c "$(curl -fsSL https://YOUR-REPO/ct/actualbudget.sh)"
   ```

## Files Included

```
actualbudget-optimised/
├── ct/
│   └── actualbudget.sh           # Proxmox host script (community-scripts style)
├── install/
│   └── actualbudget-install.sh   # Container install script
├── standalone/
│   └── actualbudget-standalone.sh  # All-in-one standalone installer
└── README.md
```

## Post-Installation Commands

| Command | Description |
|---------|-------------|
| `update` | Check for and apply Actual Budget updates |
| `systemctl status actualbudget` | Check service status |
| `systemctl restart actualbudget` | Restart the service |
| `journalctl -u actualbudget -f` | View live logs |

## Data Location

- **Data directory:** `/opt/actualbudget-data`
- **Version file:** `~/.actualbudget`
- **Service:** `actualbudget.service`

## Customisation

### Changing the Port

Edit `/etc/systemd/system/actualbudget.service` and add:
```ini
Environment=ACTUAL_PORT=5007
```

Then restart:
```bash
systemctl daemon-reload
systemctl restart actualbudget
```

### MOTD Customisation

Edit `/etc/profile.d/00_actualbudget-motd.sh` to customise the login banner.

## Troubleshooting

### Service won't start
```bash
journalctl -u actualbudget -n 100 --no-pager
```

### Check Node.js installation
```bash
node --version
npm --version
which actual-server
```

### Manual service start
```bash
export PATH=/root/.npm-global/bin:$PATH
cd /opt/actualbudget-data
actual-server
```

## Differences from Original Script

| Feature | Original | Optimised |
|---------|----------|-----------|
| MOTD banner | Basic | Custom with IP:Port display |
| Service file | Standard | Security-hardened |
| Update utility | Via community-scripts | Standalone `update` command |
| npm installation | System global | User global (cleaner) |
| Dependencies | community-scripts framework | Standalone (no external deps) |

## Credits

- Original script by [MickLesk (CanbiZ)](https://github.com/community-scripts/ProxmoxVE)
- Optimised version by Jack (Downer)
- [Actual Budget](https://actualbudget.org/) by the Actual Budget team

## Licence

MIT - See [LICENSE](https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE)
