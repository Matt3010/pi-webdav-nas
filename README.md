Of course. Here is a complete and well-documented `README.md` file for your script, suitable for a GitHub project.

-----

# Raspberry Pi WebDAV Server Automation Script

A comprehensive Bash script for deploying a secure, performant, and feature-rich WebDAV server on a Raspberry Pi or any Debian-based system. This script automates every step from package installation to advanced configuration, allowing you to set up a personal cloud storage solution in minutes.

-----

## \#\# Features

This script is designed to be a "one-stop shop" for setting up a robust WebDAV server.

  * 🚀 **Interactive Setup**: An easy-to-use interactive prompt guides you through the configuration, with sensible defaults for every option.
  * 👤 **Multi-User with Admin Privileges**: Create multiple user accounts, each with a private directory. A designated admin user has access to all directories.
  * 🗄️ **Software RAID Utility**: An integrated, interactive tool to create a software RAID array (`RAID 0`, `RAID 1`, or `RAID 5`) using `mdadm` for enhanced performance or data redundancy.
  * ⚡ **Performance Tuned**: Automatically configures Nginx for optimal performance on a Raspberry Pi, including:
      * **Multiple Worker Processes**: Utilizes all available CPU cores.
      * **Gzip Compression**: Reduces bandwidth usage for faster file transfers.
      * **File Metadata Caching**: Speeds up directory listings and file access by reducing disk I/O.
  * 💾 **Data Persistence & Migration**:
      * Running a `fresh` install safely cleans up configurations without deleting user data.
      * Automatically detects if you change the storage directory and offers to migrate all existing data to the new location.
  * 🔧 **Safe Cleanup & Reset**:
      * `fresh` command to wipe all configurations and reinstall from scratch.
      * `reset` command to act as an uninstaller, removing all packages and configurations.
  * 📜 **Auto-Generated Management Script**: Creates a companion `users.sh` script to easily add, delete, list, and change passwords for users after the initial setup.
  * 🎨 **Advanced Colored Logging**: The script provides detailed, color-coded, and timestamped output for a clear view of every action being performed.

-----

## \#\# Prerequisites

  * A server running a Debian-based OS (like Raspberry Pi OS, Debian, or Ubuntu).
  * Root or `sudo` privileges.
  * For the **RAID** feature: At least two additional, empty physical disks that can be completely erased.

-----

## \#\# Usage

### \#\#\# 1. Download the Script

Clone the repository or download the script file (`webdav_setup.sh`) to your home directory.

```bash
wget https://github.com/Matt3010/pi-webdav-nas/webdav_setup.sh
```

### \#\#\# 2. Make it Executable

```bash
chmod +x webdav_setup.sh
```

### \#\#\# 3. Run the Script

The script offers several modes of operation.

#### Standard Installation (Recommended for first-time use)

This will launch the interactive setup to configure and install the WebDAV server.

```bash
sudo ./webdav_setup.sh
```

#### RAID Setup Utility

Run this command **before** the main installation if you want to set up your storage on a RAID array. It will guide you through creating the array.

```bash
sudo ./webdav_setup.sh raid
```

⚠️ **Warning**: This operation will destroy all data on the selected disks.

#### Fresh Reinstallation

This will first run the interactive setup, then completely remove all Nginx configurations, and finally run a full reinstallation with the new settings. **Your WebDAV user data will be preserved.**

```bash
sudo ./webdav_setup.sh fresh
```

#### Reset / Uninstall

This will completely remove Nginx and all related configurations created by this script. It acts as an uninstaller. **Your WebDAV user data will be preserved.**

```bash
sudo ./webdav_setup.sh reset
```

-----

## \#\# Post-Installation: User Management

After the setup completes, a `users.sh` script will be created in the same directory. Use this script to manage your WebDAV users without needing to edit any configuration files.

**Usage:** `sudo ./users.sh [command] [username]`

  * **List all users:**
    ```bash
    sudo ./users.sh list
    ```
  * **Add a new user:**
    ```bash
    sudo ./users.sh add newuser
    ```
  * **Change a user's password:**
    ```bash
    sudo ./users.sh passwd existinguser
    ```
  * **Delete a user:**
    ```bash
    sudo ./users.sh del olduser
    ```

-----

## \#\# Script Configuration Explained

The script uses a set of default variables which can be overridden during the interactive setup.

| Variable             | Default Value                       | Description                                                                 |
| -------------------- | ----------------------------------- | --------------------------------------------------------------------------- |
| `WEBROOT`            | `/srv/webdav`                       | The root directory where all user folders and files will be stored.         |
| `USERS`              | `("user1", "user2", "admin")`       | An array of users to be created during the initial setup.                   |
| `ADMIN_USER`         | `"admin"`                           | The username of the user who will have access to all other user directories.|
| `PASSFILE`           | `/etc/nginx/webdav.passwd`          | The full path to the htpasswd file for storing user credentials.            |
| `CONF_FILE`          | `/etc/nginx/sites-available/webdav` | The path to the Nginx site configuration file.                              |
| `LOG_DIR`            | `/var/log/nginx`                    | The directory where Nginx logs will be stored.                              |
| `WEBDAV_PORT`        | `"8080"`                            | The TCP port on which the WebDAV server will listen.                        |
| `MAX_UPLOAD_SIZE`    | `"100M"`                            | The maximum size for a single file upload (e.g., `100M`, `5G`).             |
| `GZIP_LEVEL`         | `"6"`                               | The Gzip compression level (1-9). 6 is a good balance.                      |
| `AUTOINDEX_SETTING`  | `"on"`                              | Enables (`on`) or disables (`off`) directory listing in a web browser.      |
| `DEFAULT_PASSWORD`   | `"password"`                        | The initial password for users created automatically by the script.         |

-----

## \#\# Troubleshooting

  * **`Permission denied` Errors**: Ensure you are running the script with `sudo`.
  * **`Syntax error: Unterminated quoted string`**: This is likely a copy-paste error. Please ensure you copy the raw script content without any extra text or formatting.
  * **Nginx Fails to Start**: After the script runs, if Nginx doesn't start, you can check for configuration errors with `sudo nginx -t`. The detailed error message will be in the log file specified in the script's final output (e.g., `/var/log/nginx/webdav_error.log`).

-----

## \#\# License

This project is licensed under the MIT License.
