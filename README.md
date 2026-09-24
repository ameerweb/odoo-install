# Odoo multi-instance installer

Installs separate Odoo services on one Ubuntu server, with a dedicated Unix user, PostgreSQL role, virtual environment, ports, logs, and Nginx site per instance.

## Requirements

- Ubuntu 22.04 or 24.04 LTS, a fresh or reviewed host, and root access.
- A DNS name pointing to the server for each public instance.
- Backups and a maintenance window before changing an existing installation.

Copy the scripts to the server with Unix line endings and run:

```bash
sudo bash server_config.sh
```

Edit the settings at the top of `odoo_install.sh` for **each** instance. Set a unique `OE_USER`, `OE_PORT`, `LONGPOLLING_PORT`, and `WEBSITE_NAME`. Set `ADMIN_EMAIL` to a working address. Then run:

```bash
sudo bash odoo_install.sh
```

The installer refuses duplicate users, ports, services, and Nginx sites to avoid overwriting another instance. It prints the generated Odoo database manager password once; store it securely. PostgreSQL access is local, and Odoo listens on loopback behind Nginx. Nginx passes database manager requests to Odoo. The generated Odoo configuration contains `list_db = True` so initial database creation is possible. After provisioning, configure `db_name` and `dbfilter`, set `list_db = False` in `/etc/<instance>-server.conf`, then restart the service to disable the database manager through Odoo itself.

`server_config.sh` refreshes the nginx.org **stable** repository, finds the newest available package for the host, and installs that exact version automatically. No version number or key fingerprint is hardcoded. It stops if that repository cannot be refreshed or no matching package is found, rather than falling back to Ubuntu's default Nginx package (such as 1.24). The repository's signing key is imported so APT can verify package signatures. Confirm the installed version with `nginx -v` and the package origin with `apt-cache policy nginx`. Future stable releases are available through normal `apt` updates; apply those updates regularly. Mainline is a separate release channel and is not selected by this installer.

Each installation automatically writes `/etc/logrotate.d/<instance>-server`. It rotates the Odoo application log and that instance's Nginx access and error logs daily, retaining 30 rotations. Verify it with `sudo logrotate --debug /etc/logrotate.d/<instance>-server`.

If you suspect compromise (unknown cron jobs, sustained CPU use), isolate the server, preserve logs and disk evidence, rotate credentials from a clean machine, and rebuild from trusted media. Updating Nginx alone cannot remove persistence or prove the server is clean.

Check deployment with `nginx -t`, `systemctl status <instance>-server`, `ss -ltnp`, and `apt-cache policy nginx`. Keep SSH access restricted, firewall only needed public ports, maintain off-host backups, and update Odoo and its dependencies regularly.
