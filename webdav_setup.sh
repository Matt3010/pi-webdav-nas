#!/bin/bash
# WebDAV Setup Script for Raspberry Pi (v24-EN - Multi-Root Support)
# Usage:
#   ./webdav_setup.sh raid   (Interactively create a RAID array)
#   ./webdav_setup.sh        (Installs or updates the server with multiple roots)
#   ./webdav_setup.sh fresh  (Performs a safe cleanup AND reinstalls)
#   ./webdav_setup.sh reset  (ONLY performs a safe cleanup)

set -e

# --- Colored Logging Functions ---
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD_GREEN='\033[1;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
    local level="$1"
    local msg="$2"
    local timestamp="[$(date '+%T')]"
    
    case "$level" in
        HEADER)
            echo -e "\n${CYAN}==== $msg ====${NC}"
            return
            ;;
        STEP)
            echo -e "--> $msg"
            return
            ;;
        WARN)
            color="$YELLOW"
            prefix="[WARNING]"
            ;;
        CONFIG)
            color="$MAGENTA"
            prefix="[CONFIG]"
            ;;
        SUCCESS)
            color="$BOLD_GREEN"
            prefix="[SUCCESS]"
            ;;
        ERROR)
            color="$RED"
            prefix="[ERROR]"
            ;;
        *)
            color="$GREEN"
            prefix="[INFO]"
            ;;
    esac
    
    echo -e "${color}${prefix}${NC} ${timestamp} $msg"
}

# --- Default Configuration Variables ---
# These will be populated by ask_for_settings
WEBROOTS=()
WEBDAV_PORTS=()
# Global settings
USERS=("admin")
ADMIN_USER="admin"
PASSFILE="/etc/nginx/webdav.passwd"
LOG_DIR="/var/log/nginx"
NGINX_ERROR_LOG_FILE="webdav_error.log"
MANAGEMENT_SCRIPT="users.sh"
MAX_UPLOAD_SIZE="100M"
GZIP_LEVEL="6"
AUTOINDEX_SETTING="on"
DEFAULT_PASSWORD="password"

# ==============================================================================
#                              SETUP FUNCTIONS
# ==============================================================================

ask_for_settings() {
    # --- Per-Location Settings ---
    log "HEADER" "Interactive Configuration"
    log "STEP" "You will now configure one or more WebDAV locations."
    
    local counter=1
    while true; do
        log "CONFIG" "Configuring WebDAV Location #$counter"
        
        local default_root="/srv/webdav"
        if [ "$counter" -gt 1 ]; then
            default_root="/srv/webdav${counter}"
        fi
        read -p "Enter the root directory for this location [$default_root]: " input_root
        WEBROOTS+=("${input_root:-$default_root}")
        
        local default_port=$((8079 + counter))
        read -p "Enter the port for this location to listen on [$default_port]: " input_port
        WEBDAV_PORTS+=("${input_port:-$default_port}")

        read -p "Do you want to add another WebDAV location? (y/n) [n]: " add_another
        if [[ ! "$add_another" =~ ^[yY]$ ]]; then
            break
        fi
        counter=$((counter + 1))
    done

    # --- Global Settings ---
    log "HEADER" "Global Settings"
    log "STEP" "The following settings will apply to ALL configured locations."

    read -p "Enter the admin username [$ADMIN_USER]: " input
    ADMIN_USER=${input:-$ADMIN_USER}
    
    read -p "Enter the full path for the password file [$PASSFILE]: " input
    PASSFILE=${input:-$PASSFILE}
    
    read -p "Enter the maximum file upload size (e.g., 100M, 2G) [$MAX_UPLOAD_SIZE]: " input
    MAX_UPLOAD_SIZE=${input:-$MAX_UPLOAD_SIZE}
    
    while true; do
        read -p "Enter Gzip compression level (1-9) [$GZIP_LEVEL]: " input
        GZIP_LEVEL=${input:-$GZIP_LEVEL}
        if [[ "$GZIP_LEVEL" =~ ^[1-9]$ ]]; then
            break
        else
            log "WARN" "Invalid input. Please enter a number between 1 and 9."
            GZIP_LEVEL="6"
        fi
    done
    
    read -p "Enable directory listing in browser? (y/n) [y]: " input
    if [[ "${input:-y}" =~ ^[yY]$ ]]; then
        AUTOINDEX_SETTING="on"
    else
        AUTOINDEX_SETTING="off"
    fi
    
    read -p "Enter the default password for NEWLY created users [$DEFAULT_PASSWORD]: " input
    DEFAULT_PASSWORD=${input:-$DEFAULT_PASSWORD}
    
    log "SUCCESS" "Configuration received."
}

run_raid_setup() {
    log "HEADER" "RAID Array Setup Utility"
    log "WARN" "This utility will DESTROY ALL DATA on the selected disks."
    read -p "Press Enter to continue, or CTRL+C to abort."
    
    log "INFO" "Installing 'mdadm' software RAID tool..."
    sudo apt-get update >/dev/null
    sudo apt-get install -y mdadm >/dev/null
    log "SUCCESS" "'mdadm' installed."
    
    log "INFO" "Scanning for available, non-boot disks..."
    root_disk=$(findmnt -n -o SOURCE / | sed -E 's/p?[0-9]+$//' | sed 's,/dev/,,')
    mapfile -t available_disks < <(lsblk -dno NAME,SIZE,TYPE | grep 'disk' | grep -v "$root_disk" | awk '{print "/dev/"$1, "(" $2 ")"}')
    
    if [ ${#available_disks[@]} -eq 0 ]; then
        log "ERROR" "No suitable non-boot disks were found to create a RAID array."
        log "INFO" "This is normal if you only have one disk (the boot disk) in your system."
        log "STEP" "You can proceed with a standard setup on your main disk by running:"
        echo -e "\n  ${BOLD_GREEN}sudo ./webdav_setup.sh${NC}\n"
        exit 1
    fi
    
    log "STEP" "Please choose the disks to include in the array from the list below."
    PS3="Select a disk to add (or 'Done' to finish): "
    selected_disks=()
    select disk_choice in "${available_disks[@]}" "Done"; do
        if [ "$disk_choice" == "Done" ]; then
            break
        elif [ -n "$disk_choice" ]; then
            selected_disks+=("$(echo "$disk_choice" | awk '{print $1}')")
            log "SUCCESS" "Added $(echo "$disk_choice" | awk '{print $1}'). Current selection: ${selected_disks[*]}"
        else
            log "WARN" "Invalid selection."
        fi
    done
    
    if [ ${#selected_disks[@]} -lt 2 ]; then
        log "ERROR" "You must select at least 2 disks. Aborting."
        exit 1
    fi
    
    log "STEP" "Please choose a RAID level."
    raid_levels=("RAID 0 (Striping - Performance, No Redundancy)" "RAID 1 (Mirroring - Redundancy)" "RAID 5 (Parity - Balance, requires >= 3 disks)")
    PS3="Select a RAID level: "
    select raid_choice in "${raid_levels[@]}"; do
        if [ -n "$raid_choice" ]; then
            raid_level=$(echo "$raid_choice" | awk '{print $2}')
            break
        else
            log "WARN" "Invalid selection."
        fi
    done
    
    if [ "$raid_level" == "5" ] && [ ${#selected_disks[@]} -lt 3 ]; then
        log "ERROR" "RAID 5 requires at least 3 disks. Aborting."
        exit 1
    fi
    
    log "HEADER" "Final Confirmation"
    log "WARN" "You are about to create a RAID $raid_level array on: ${selected_disks[*]}"
    log "ERROR" "ALL DATA ON THESE DISKS WILL BE PERMANENTLY ERASED."
    read -p "Type 'YES' in all caps to proceed: " confirm
    if [ "$confirm" != "YES" ]; then
        log "INFO" "Operation cancelled by user."
        exit 0
    fi
    
    local array_device="/dev/md0"
    log "INFO" "Creating RAID $raid_level array at $array_device..."
    sudo mdadm --create "$array_device" --level="$raid_level" --raid-devices=${#selected_disks[@]} "${selected_disks[@]}" --run
    
    log "INFO" "Waiting for array to assemble..."
    sleep 10
    
    log "INFO" "Creating ext4 filesystem on the array..."
    sudo mkfs.ext4 -F "$array_device"
    
    log "STEP" "Where should the new RAID array be mounted? (e.g., /srv/raid)"
    read -p "Mount point: " mount_point
    sudo mkdir -p "$mount_point"
    
    log "INFO" "Adding array to /etc/fstab for automounting..."
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$array_device")
    echo "UUID=$uuid $mount_point ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
    
    log "INFO" "Updating mdadm configuration..."
    sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
    sudo update-initramfs -u
    
    log "INFO" "Mounting the new array..."
    sudo mount -a
    
    log "SUCCESS" "RAID array created and mounted at $mount_point!"
}

run_cleanup() {
    log "HEADER" "PHASE 1: System Cleanup"
    log "WARN" "This operation will remove Nginx and all its WebDAV configurations."
    log "WARN" "User data in your configured WebDAV directories will NOT be touched."
    
    read -p "Are you sure you want to proceed with the cleanup? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log "INFO" "Operation cancelled by user."
        exit 0
    fi
    
    log "STEP" "Stopping Nginx service..."
    sudo systemctl stop nginx || true
    
    log "STEP" "Completely removing Nginx packages..."
    sudo apt-get remove --purge -y 'nginx*' >/dev/null || true
    sudo apt-get autoremove -y >/dev/null || true
    
    log "STEP" "Deleting residual configuration folders and files..."
    sudo rm -rf /etc/nginx /var/lib/nginx
    sudo rm -f "$PASSFILE"
    
    log "SUCCESS" "Cleanup phase completed."
}

run_setup() {
    log "HEADER" "PHASE 2: WebDAV Installation and Configuration"
    
    log "INFO" "Installing packages: nginx and apache2-utils"
    sudo apt-get update >/dev/null
    sudo apt-get install -y nginx-full apache2-utils >/dev/null
    log "SUCCESS" "Packages installed."
    
    log "CONFIG" "Nginx: Enabling multiple workers and file cache"
    sudo sed -i 's/^\s*worker_processes\s\+.*;/worker_processes auto;/' /etc/nginx/nginx.conf
    sudo tee /etc/nginx/conf.d/00-performance.conf >/dev/null <<EOL
open_file_cache max=2000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
EOL
    log "STEP" "Nginx performance tuned."
    
    log "INFO" "Managing WebDAV Folders and Permissions"
    for webroot in "${WEBROOTS[@]}"; do
        log "STEP" "Setting up directory: $webroot"
        sudo mkdir -p "$webroot"
        for u in "${USERS[@]}"; do
            sudo mkdir -p "$webroot/$u"
        done
        sudo chown -R www-data:www-data "$webroot"
        sudo chmod -R 750 "$webroot"
    done
    log "STEP" "Folders and permissions set for all locations."
    
    log "INFO" "Creating/updating users (does not overwrite passwords)"
    if [ ! -f "$PASSFILE" ]; then
        log "STEP" "No password file found. Creating a new one..."
        sudo htpasswd -cb "$PASSFILE" "${USERS[0]}" "$DEFAULT_PASSWORD"
        log "STEP" "New user '${USERS[0]}' added."
        for u in "${USERS[@]:1}"; do
            sudo htpasswd -b "$PASSFILE" "$u" "$DEFAULT_PASSWORD"
            log "STEP" "New user '$u' added."
        done
    else
        log "STEP" "Password file exists. Verifying users..."
        for u in "${USERS[@]}"; do
            if sudo grep -q "^${u}:" "$PASSFILE"; then
                line=$(sudo grep "^${u}:" "$PASSFILE")
                hash="${line#*:}"
                initial="${hash:0:1}"
                len=$((${#hash} - 1))
                asterisks=$(printf '*%.0s' $(seq 1 $len))
                log "STEP" "User '$u' already present. Hash: ${initial}${asterisks}"
            else
                sudo htpasswd -b "$PASSFILE" "$u" "$DEFAULT_PASSWORD"
                log "STEP" "New user '$u' added."
            fi
        done
    fi
    log "WARN" "Default passwords are set to '$DEFAULT_PASSWORD'. Change them using './users.sh passwd <username>'"
    
    log "CONFIG" "Nginx: Creating configurations for WebDAV sites"
    # Clean up old configs before creating new ones
    sudo rm -f /etc/nginx/sites-available/webdav_*
    sudo rm -f /etc/nginx/sites-enabled/webdav_*
    
    for i in "${!WEBROOTS[@]}"; do
        local current_webroot="${WEBROOTS[$i]}"
        local current_port="${WEBDAV_PORTS[$i]}"
        
        # Sanitize webroot path to create a valid filename
        local sanitized_name
        sanitized_name=$(echo "$current_webroot" | tr -c '[:alnum:]' '_')
        local current_conf_file="/etc/nginx/sites-available/webdav_${sanitized_name}"
        
        log "STEP" "Generating config for '$current_webroot' on port $current_port"
        sudo tee "$current_conf_file" >/dev/null <<EOL
server {
    listen $current_port;
    server_name _;

    access_log $LOG_DIR/webdav_access_${sanitized_name}.log;
    error_log $LOG_DIR/${NGINX_ERROR_LOG_FILE};

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level $GZIP_LEVEL;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml;
    
    set \$user_root $current_webroot/;
    if (\$remote_user != "$ADMIN_USER") {
        set \$user_root "$current_webroot/\$remote_user/";
    }
    
    location / {
        alias \$user_root; 
        client_max_body_size $MAX_UPLOAD_SIZE; 
        auth_basic "WebDAV Restricted Area"; 
        auth_basic_user_file $PASSFILE;
        autoindex $AUTOINDEX_SETTING; 
        dav_methods PUT DELETE MKCOL COPY MOVE; 
        dav_ext_methods PROPFIND OPTIONS;
        create_full_put_path on; 
        dav_access user:rw group:r all:r;
    }
}
EOL
        log "INFO" "Enabling site: $(basename "$current_conf_file")"
        sudo ln -sf "$current_conf_file" "/etc/nginx/sites-enabled/$(basename "$current_conf_file")"
    done
    
    log "CONFIG" "Creating management script '$MANAGEMENT_SCRIPT'"
    sudo tee "$MANAGEMENT_SCRIPT" >/dev/null <<EOM
#!/bin/bash
set -e
PASSFILE="$PASSFILE"

show_usage() {
    echo "Usage: \$0 [command] [username]"
    echo "Commands:"
    echo "  add      <username>  - Adds a new user (prompts for password)."
    echo "  passwd   <username>  - Changes an existing user's password."
    echo "  del      <username>  - Deletes a user."
    echo "  list                 - Lists all users."
}

if [[ ! -f "\$PASSFILE" ]]; then
    echo "Error: The password file '\$PASSFILE' does not exist." >&2
    exit 1
fi

case "\$1" in
    add | passwd)
        [ -z "\$2" ] && { echo "Error: a username must be specified."; exit 1; }
        sudo htpasswd "\$PASSFILE" "\$2"
        echo "✅ User '\$2' was added/updated successfully."
        ;;
    del)
        [ -z "\$2" ] && { echo "Error: a username must be specified."; exit 1; }
        sudo htpasswd -D "\$PASSFILE" "\$2"
        echo "✅ User '\$2' was deleted successfully."
        ;;
    list)
        echo "--- Configured WebDAV Users ---"
        sudo cut -d: -f1 "\$PASSFILE"
        echo "-----------------------------"
        ;;
    *)
        show_usage
        ;;
esac
EOM
    sudo chmod +x "$MANAGEMENT_SCRIPT"
    log "STEP" "Script '$MANAGEMENT_SCRIPT' created."
    
    log "INFO" "Restarting Nginx to apply all changes"
    sudo nginx -t && sudo systemctl restart nginx
    
    log "HEADER" "Setup Completed Successfully"
    log "SUCCESS" "WebDAV server is active and configured!"
    for i in "${!WEBROOTS[@]}"; do
        log "INFO" "Access point: http://<RASPBERRY_IP>:${WEBDAV_PORTS[$i]} -> ${WEBROOTS[$i]}"
    done
    log "INFO" "Nginx Error Log: $LOG_DIR/$NGINX_ERROR_LOG_FILE"
    log "INFO" "User Management: use 'sudo ./$MANAGEMENT_SCRIPT [command]'"
}

# ==============================================================================
#                               MAIN EXECUTION LOGIC
# ==============================================================================
case "$1" in
    raid)
        run_raid_setup
        ;;
    fresh)
        ask_for_settings
        run_cleanup
        run_setup
        ;;
    reset)
        run_cleanup
        ;;
    *)
        ask_for_settings
        run_setup
        ;;
esac
