# Pi WebDAV NAS

A Bash installer for running a multi-user WebDAV storage server on Raspberry Pi OS, Debian, or Ubuntu with Nginx.

The project is intentionally conservative: it manages only its own Nginx files, preserves existing Nginx sites, never recursively changes ownership/permissions of existing WebDAV data, and keeps user data when reconfiguring or uninstalling.

## What it provides

- Multiple WebDAV storage roots, each on its own TCP port.
- HTTP Basic Authentication with no hard-coded/default password.
- One admin account that can access the whole configured WebDAV root.
- Regular users automatically restricted to `<webroot>/<username>/`.
- Persistent configuration in `/etc/pi-webdav-nas/config`.
- `pi-webdav-users` command for adding/removing users and changing passwords.
- Safe `install`, `reconfigure`, `fresh`, and `reset` modes.
- Optional interactive `mdadm` RAID 0/1/5 creation with destructive-operation safeguards.
- GitHub Actions checks for Bash syntax, ShellCheck, helper validation, and destructive-cleanup regressions.

## Security model

**The generated WebDAV endpoints use plain HTTP and Basic Authentication. Do not expose their ports directly to the public Internet.**

Use one of these approaches:

- access WebDAV only on a trusted LAN;
- access it through a trusted VPN such as WireGuard;
- place a properly configured HTTPS reverse proxy in front of it.

Basic Authentication credentials are protected only when the transport itself is trusted/encrypted.

## Requirements

- Raspberry Pi OS, Debian, or Ubuntu with `systemd`.
- Root access (`sudo`).
- A dedicated directory for each WebDAV root, such as `/srv/webdav` or `/mnt/storage/webdav`.
- For the RAID utility: at least two non-root physical disks that may be completely erased.

## Install

Download the installer:

```bash
wget https://raw.githubusercontent.com/Matt3010/pi-webdav-nas/refs/heads/master/webdav_setup.sh
chmod +x webdav_setup.sh
```

Run it:

```bash
sudo ./webdav_setup.sh install
```

Running the script with no command is equivalent to `install`:

```bash
sudo ./webdav_setup.sh
```

On the first run, the script asks for:

- one or more WebDAV root directories;
- one unique TCP port for each root;
- the admin username;
- maximum upload size;
- gzip level;
- whether browser directory indexes are enabled.

It then prompts for the admin password using `htpasswd`. There is **no default password**.

After the first successful configuration, settings are stored in:

```text
/etc/pi-webdav-nas/config
```

A later `install` re-applies that saved configuration without wiping unrelated Nginx configuration.

## Commands

### Install / apply saved configuration

```bash
sudo ./webdav_setup.sh install
```

If no saved configuration exists, interactive setup starts. Otherwise the saved configuration is applied.

### Reconfigure

```bash
sudo ./webdav_setup.sh reconfigure
```

Lets you change storage roots, ports, admin username, upload size, gzip level, and directory listing.

Changing a WebDAV root does **not** automatically move data from the previous root. Move/copy data yourself before removing an old storage location.

### Fresh configuration rebuild

```bash
sudo ./webdav_setup.sh fresh
```

Recreates only the Nginx/configuration files managed by Pi WebDAV NAS and reapplies settings.

It preserves:

- WebDAV data;
- the existing password file;
- unrelated Nginx sites and configuration;
- the Nginx package itself.

### Reset / uninstall project configuration

```bash
sudo ./webdav_setup.sh reset
```

Removes only Pi WebDAV NAS configuration. It does **not** remove Nginx and does **not** delete WebDAV data.

The command separately asks whether the saved credential file should also be removed.

### RAID setup

```bash
sudo ./webdav_setup.sh raid
```

The RAID helper can create `/dev/md0` as RAID 0, RAID 1, or RAID 5.

Safety checks include:

- excluding physical disks backing `/`;
- refusing disks with mounted filesystems;
- preventing duplicate disk selection;
- refusing to overwrite an existing `/dev/md0`;
- warning when existing disk signatures are detected;
- requiring the literal confirmation `ERASE` before creation;
- refusing non-empty mount points;
- avoiding duplicate `/etc/fstab` and `mdadm.conf` entries.

**RAID is not a backup.** Keep important data backed up separately.

## User management

After installation, use the system command:

```bash
sudo pi-webdav-users list
```

Add a user:

```bash
sudo pi-webdav-users add matteo
```

This creates the credentials and a private `matteo/` directory in every configured WebDAV root.

Change a password:

```bash
sudo pi-webdav-users passwd matteo
```

Remove login access:

```bash
sudo pi-webdav-users del matteo
```

`del` removes the credentials only. **The user's data directories are deliberately preserved.** The configured admin account cannot be deleted through this command; reconfigure the server first if you need to change administrators.

## Multi-user layout

For a root configured as `/srv/webdav`:

```text
/srv/webdav/
├── admin/
├── alice/
└── bob/
```

A regular authenticated user is routed by Nginx to:

```text
/srv/webdav/<authenticated-user>/
```

The configured admin user is routed to:

```text
/srv/webdav/
```

The routing is implemented with an Nginx `map` based on `$remote_user`, avoiding rewrite-phase `if` logic for authentication-dependent paths.

## Files managed by the project

The installer intentionally limits its changes to project-owned files:

```text
/etc/pi-webdav-nas/config
/etc/nginx/pi-webdav.passwd
/etc/nginx/conf.d/pi-webdav-map.conf
/etc/nginx/sites-available/pi-webdav-*.conf
/etc/nginx/sites-enabled/pi-webdav-*.conf
/usr/local/sbin/pi-webdav-users
```

It does **not** run `apt purge nginx`, remove `/etc/nginx`, or recursively run `chown -R` / `chmod -R` over your data.

The top-level WebDAV directory and each managed user directory are set to `www-data:www-data` with mode `750`; existing contents below them are left unchanged.

## WebDAV compatibility

The installer uses `nginx-full` plus the DAV extension module and enables:

- `PUT`
- `DELETE`
- `MKCOL`
- `COPY`
- `MOVE`
- `PROPFIND`
- `OPTIONS`

`LOCK` / `UNLOCK` are not enabled because support varies by DAV extension/module build and client. If a client requires locking semantics, test that client explicitly before relying on it.

## Troubleshooting

Validate Nginx configuration:

```bash
sudo nginx -t
```

Check the service:

```bash
sudo systemctl status nginx
```

Follow the project error log:

```bash
sudo tail -f /var/log/nginx/pi-webdav-error.log
```

Check listening ports:

```bash
sudo ss -ltnp
```

List configured users:

```bash
sudo pi-webdav-users list
```

Show saved configuration:

```bash
sudo cat /etc/pi-webdav-nas/config
```

## Development checks

Run locally:

```bash
bash -n webdav_setup.sh tests/helpers_test.sh
shellcheck webdav_setup.sh tests/helpers_test.sh
bash tests/helpers_test.sh
```

GitHub Actions runs the same checks on pushes and pull requests.

## License

MIT. See [LICENSE](LICENSE).
