# Proxmox Scripts Collection

A curated collection of optimised Proxmox LXC installation scripts for self-hosted applications. Each script creates a fully configured container with custom MOTD banners, systemd services, and easy update commands.

## Available Applications

### Actual Budget

[Actual Budget](https://actualbudget.org/) is a local-first personal finance tool with bank sync capabilities.

#### Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yterterian/proxmox-scripts/master/Actual_Budget/install.sh)
```

#### Alternative Installation Methods

##### Clone Repository First

```bash
git clone https://github.com/yterterian/proxmox-scripts.git
cd proxmox-scripts/Actual_Budget
chmod +x install.sh
./install.sh
```

##### Download and Review

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/yterterian/proxmox-scripts/master/Actual_Budget/install.sh
cat install.sh  # Review the script
chmod +x install.sh
./install.sh
```

#### What You Get

- Actual Budget running on port 5006
- Systemd service for automatic startup
- Custom MOTD banner showing IP address and port
- `update` command for easy version updates
- Debian 12/13 based LXC container

#### Post-Installation Commands

| Command | Description |
|---------|-------------|
| `update` | Check for and apply Actual Budget updates |
| `systemctl status actualbudget` | Check service status |
| `systemctl restart actualbudget` | Restart the service |
| `journalctl -u actualbudget -f` | View live logs |

[View detailed documentation](./Actual_Budget/README.md)

---

## Installation Requirements

Before running any script, ensure you have:

1. **Proxmox VE** installed and running
2. **Root access** to your Proxmox host or LXC container
3. **Internet connection** for downloading packages
4. **Template:** Debian 12 or 13 (recommended)

## Container Recommendations

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **Disk** | 4GB | 8GB |
| **RAM** | 1GB | 2GB |
| **CPU Cores** | 1 | 2 |
| **Network** | DHCP or Static IP | Static IP preferred |

## Script Structure

Each application folder contains:

```
Application_Name/
├── README.md                      # Detailed documentation
├── install.sh                     # Quick install launcher
├── actualbudget-standalone.sh     # Standalone installer (run inside container)
├── actualbudget.sh                # Proxmox host script (community-scripts style)
└── actualbudget-install.sh        # Container install script
```

## Usage Patterns

### Pattern 1: Quick One-Liner (Recommended)

Create your LXC container manually in Proxmox, then run inside the container:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yterterian/proxmox-scripts/master/[APP_FOLDER]/install.sh)
```

### Pattern 2: Download and Inspect

If you prefer to review scripts before execution:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/yterterian/proxmox-scripts/master/[APP_FOLDER]/install.sh
cat install.sh  # Review the script
chmod +x install.sh
./install.sh
```

### Pattern 3: Community-Scripts Style (Advanced)

Run from Proxmox host to auto-create container:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/yterterian/proxmox-scripts/master/[APP_FOLDER]/[app].sh)"
```

## Features

- **Custom MOTD Banners**: See IP address, port, and service status on login
- **Systemd Integration**: Automatic startup and service management
- **Update Utilities**: Simple `update` commands for version management
- **Security Hardened**: Service files with proper user permissions and resource limits
- **Standalone**: No external framework dependencies required

## Roadmap

Future applications to be added:

- [ ] Home Assistant
- [ ] Nextcloud
- [ ] Jellyfin
- [ ] Vaultwarden
- [ ] Portainer
- [ ] Pi-hole
- [ ] Nginx Proxy Manager
- [ ] Uptime Kuma

## Contributing

Contributions welcome! If you have an optimised Proxmox script:

1. Fork this repository
2. Create a new folder for your application
3. Include all required files (README.md, install scripts)
4. Submit a pull request

## Credits

- Scripts optimised and maintained by [@yterterian](https://github.com/yterterian)
- Inspired by [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
- Original Actual Budget script by [MickLesk (CanbiZ)](https://github.com/community-scripts/ProxmoxVE)

## Support

- **Issues**: [GitHub Issues](https://github.com/yterterian/proxmox-scripts/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yterterian/proxmox-scripts/discussions)

## License

MIT License - See [LICENSE](./LICENSE) for details

---

**Made with ❤️ for the Proxmox self-hosting community**
