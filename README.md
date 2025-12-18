# Odoo Install Script

This repository contains scripts to automate the installation of Odoo on a Linux server.

## Scripts

### 1. `odoo_install.sh` (Recommended)

This is the main installation script, updated to be interactive and support a checkpoint system.

**Author:** abdalmola

**Features:**
- Interactive setup (asks for username, Odoo version, port, etc.)
- Creates a system user and PostgreSQL user.
- Clones Odoo from GitHub.
- Installs all system and Python dependencies (including creating a virtual environment).
- Sets up a systemd service.
- Supports resuming installation if interrupted (Checkpoint system).

**Usage:**

1.  Make the script executable:
    ```bash
    chmod +x odoo_install.sh
    ```
2.  Run the script:
    ```bash
    ./odoo_install.sh
    ```
3.  Follow the on-screen prompts.

### 2. `server_config.sh` (Optional)

This script can be used to pre-configure the server, specifically if you need to install Nginx, Certbot (SSL), or a specific version of PostgreSQL (e.g., v16) before running the Odoo installer.

**Note:** `odoo_install.sh` handles basic dependency installation, so this script is primarily useful for the Nginx/SSL setup part or if you want to ensure a specific server environment.

**Usage:**

```bash
chmod +x server_config.sh
sudo ./server_config.sh
```

### 3. `odoo_install_old.sh`

This is the previous version of the installation script (modified by Ameer Almughalis). It is kept for backup purposes.

## Notes

- Ensure you have `sudo` privileges before running the scripts.
- `odoo_install.sh` assumes you are running on a fresh Ubuntu server (or compatible Debian-based system).
