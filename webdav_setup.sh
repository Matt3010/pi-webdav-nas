#!/usr/bin/env bash
# Pi WebDAV NAS setup for Raspberry Pi OS / Debian / Ubuntu.
# Safe-by-default installer: it manages only files created by this project.

set -Eeuo pipefail

readonly PROJECT_NAME="pi-webdav-nas"
readonly STATE_DIR="/etc/${PROJECT_NAME}"
readonly CONFIG_FILE="${STATE_DIR}/config"
readonly PASSFILE="/etc/nginx/pi-webdav.passwd"
readonly MAP_FILE="/etc/nginx/conf.d/pi-webdav-map.conf"
readonly SITE_AVAILABLE_DIR="/etc/nginx/sites-available"
readonly SITE_ENABLED_DIR="/etc/nginx/sites-enabled"
readonly SITE_PREFIX="pi-webdav-"
readonly MANAGEMENT_SCRIPT="/usr/local/sbin/pi-webdav-users"

WEBROOTS=()
WEBDAV_PORTS=()
ADMIN_USER="admin"
MAX_UPLOAD_SIZE="100M"
GZIP_LEVEL="6"
AUTOINDEX_SETTING="on"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD_GREEN='\033[1;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    local level="$1"
    local msg="$2"
    local color="$GREEN"
    local prefix="[INFO]"
    local timestamp
    timestamp="[$(date '+%T')]"

    case "$level" in
        HEADER)
            printf '\n%b==== %s ====%b\n' "$CYAN" "$msg" "$NC"
            return
            ;;
        STEP)
            printf '%s\n' "--> $msg"
            return
            ;;
        WARN) color="$YELLOW"; prefix="[WARNING]" ;;
        CONFIG) color="$MAGENTA"; prefix="[CONFIG]" ;;
        SUCCESS) color="$BOLD_GREEN"; prefix="[SUCCESS]" ;;
        ERROR) color="$RED"; prefix="[ERROR]" ;;
    esac

    printf '%b%s%b %s %s\n' "$color" "$prefix" "$NC" "$timestamp" "$msg"
}

fatal() {
    log ERROR "$1"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]:-unknown}
    log ERROR "Command failed near line ${line_no} (exit code ${exit_code})."
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        fatal "Run this command as root, for example: sudo ./webdav_setup.sh $*"
    fi
}

is_valid_username() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_valid_size() {
    [[ "$1" =~ ^[0-9]+[kKmMgG]?$ ]]
}

is_safe_webroot() {
    local path="$1"
    [[ "$path" == /* ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1

    case "$path" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/usr|/var)
            return 1
            ;;
    esac
    return 0
}

normalize_webroot() {
    realpath -m -- "$1"
}

port_already_selected() {
    local candidate="$1"
    local port
    for port in "${WEBDAV_PORTS[@]:-}"; do
        [[ "$port" == "$candidate" ]] && return 0
    done
    return 1
}

warn_if_port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0

    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
        log WARN "TCP port ${port} already appears to be in use. Nginx validation will fail if there is a real conflict."
    fi
}

save_config() {
    install -d -m 700 "$STATE_DIR"
    local tmp
    tmp=$(mktemp)

    {
        printf 'WEBROOTS=('; printf '%q ' "${WEBROOTS[@]}"; printf ')\n'
        printf 'WEBDAV_PORTS=('; printf '%q ' "${WEBDAV_PORTS[@]}"; printf ')\n'
        printf 'ADMIN_USER=%q\n' "$ADMIN_USER"
        printf 'MAX_UPLOAD_SIZE=%q\n' "$MAX_UPLOAD_SIZE"
        printf 'GZIP_LEVEL=%q\n' "$GZIP_LEVEL"
        printf 'AUTOINDEX_SETTING=%q\n' "$AUTOINDEX_SETTING"
    } >"$tmp"

    install -m 600 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # The file is generated only by save_config() and is root-writable.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    return 0
}

show_current_locations() {
    local i
    for i in "${!WEBROOTS[@]}"; do
        printf '  %d) %s -> TCP %s\n' "$((i + 1))" "${WEBROOTS[$i]}" "${WEBDAV_PORTS[$i]}"
    done
}

configure_locations() {
    WEBROOTS=()
    WEBDAV_PORTS=()
    local counter=1

    while true; do
        local default_root="/srv/webdav"
        (( counter > 1 )) && default_root="/srv/webdav${counter}"

        local input_root=""
        local normalized_root=""
        while true; do
            read -r -p "Root directory for WebDAV location #${counter} [${default_root}]: " input_root
            normalized_root=$(normalize_webroot "${input_root:-$default_root}")
            if ! is_safe_webroot "$normalized_root"; then
                log WARN "Unsafe WebDAV root. Choose a dedicated absolute directory such as /srv/webdav or /mnt/storage/webdav."
                continue
            fi
            if [[ -d "$normalized_root" && -n "$(find "$normalized_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                log WARN "${normalized_root} already exists and is not empty. Existing contents will not be recursively chowned or chmodded."
                local confirm_existing=""
                read -r -p "Use this directory anyway? (y/N): " confirm_existing
                [[ "$confirm_existing" =~ ^[yY]$ ]] || continue
            fi
            break
        done
        WEBROOTS+=("$normalized_root")

        local default_port=$((8079 + counter))
        local input_port=""
        while true; do
            read -r -p "TCP port for this location [${default_port}]: " input_port
            input_port=${input_port:-$default_port}
            if ! is_valid_port "$input_port"; then
                log WARN "Port must be an integer between 1 and 65535."
                continue
            fi
            if port_already_selected "$input_port"; then
                log WARN "Port ${input_port} is already assigned to another WebDAV location."
                continue
            fi
            warn_if_port_in_use "$input_port"
            break
        done
        WEBDAV_PORTS+=("$input_port")

        local add_another=""
        read -r -p "Add another WebDAV location? (y/N): " add_another
        [[ "$add_another" =~ ^[yY]$ ]] || break
        ((counter += 1))
    done
}

ask_for_settings() {
    log HEADER "Interactive configuration"

    if (( ${#WEBROOTS[@]} > 0 )); then
        log STEP "Current WebDAV locations:"
        show_current_locations
        local keep_locations=""
        read -r -p "Keep these locations? (Y/n): " keep_locations
        if [[ "$keep_locations" =~ ^[nN]$ ]]; then
            configure_locations
        fi
    else
        configure_locations
    fi

    local input=""
    while true; do
        read -r -p "Admin username [${ADMIN_USER}]: " input
        input=${input:-$ADMIN_USER}
        if is_valid_username "$input"; then
            ADMIN_USER="$input"
            break
        fi
        log WARN "Username must start with a letter or digit and contain only letters, digits, dot, underscore or hyphen (max 64 chars)."
    done

    while true; do
        read -r -p "Maximum upload size [${MAX_UPLOAD_SIZE}]: " input
        input=${input:-$MAX_UPLOAD_SIZE}
        if is_valid_size "$input"; then
            MAX_UPLOAD_SIZE="$input"
            break
        fi
        log WARN "Use an Nginx size such as 100M, 2G, 512K, or 0."
    done

    while true; do
        read -r -p "Gzip compression level (1-9) [${GZIP_LEVEL}]: " input
        input=${input:-$GZIP_LEVEL}
        if [[ "$input" =~ ^[1-9]$ ]]; then
            GZIP_LEVEL="$input"
            break
        fi
        log WARN "Gzip level must be between 1 and 9."
    done

    read -r -p "Enable browser directory listing? (Y/n): " input
    if [[ "$input" =~ ^[nN]$ ]]; then
        AUTOINDEX_SETTING="off"
    else
        AUTOINDEX_SETTING="on"
    fi

    save_config
    log SUCCESS "Configuration saved to ${CONFIG_FILE}."
}

install_packages() {
    log INFO "Installing required packages: nginx-full, apache2-utils, iproute2"
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-full apache2-utils iproute2 >/dev/null
    log SUCCESS "Required packages are installed."
}

ensure_password_file() {
    install -d -m 755 "$(dirname "$PASSFILE")"

    if [[ ! -s "$PASSFILE" ]]; then
        log STEP "Creating WebDAV credentials for admin '${ADMIN_USER}'."
        log WARN "Choose a strong password. There is no default password."
        htpasswd -c "$PASSFILE" "$ADMIN_USER"
        chmod 640 "$PASSFILE"
        chown root:www-data "$PASSFILE"
        return
    fi

    if ! grep -Fq "${ADMIN_USER}:" "$PASSFILE"; then
        log STEP "Admin '${ADMIN_USER}' is not in the credentials file yet. Set a password now."
        htpasswd "$PASSFILE" "$ADMIN_USER"
    fi

    chmod 640 "$PASSFILE"
    chown root:www-data "$PASSFILE"
}

list_users() {
    [[ -f "$PASSFILE" ]] || return 0
    cut -d: -f1 "$PASSFILE" | sed '/^[[:space:]]*$/d'
}

prepare_webroots() {
    local webroot
    local user

    for webroot in "${WEBROOTS[@]}"; do
        log STEP "Preparing ${webroot}"
        mkdir -p "$webroot"
        # Only the WebDAV root itself is adjusted. Existing contents are never changed recursively.
        chown www-data:www-data "$webroot"
        chmod 750 "$webroot"

        while IFS= read -r user; do
            [[ -n "$user" ]] || continue
            mkdir -p "$webroot/$user"
            chown www-data:www-data "$webroot/$user"
            chmod 750 "$webroot/$user"
        done < <(list_users)
    done
}

nginx_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

remove_managed_nginx_files() {
    rm -f "${SITE_AVAILABLE_DIR}/${SITE_PREFIX}"*.conf
    rm -f "${SITE_ENABLED_DIR}/${SITE_PREFIX}"*.conf
    rm -f "$MAP_FILE"
}

write_nginx_map() {
    local tmp
    tmp=$(mktemp)
    {
        printf '# Generated by %s. Do not edit manually.\n' "$PROJECT_NAME"
        local i root escaped_root
        for i in "${!WEBROOTS[@]}"; do
            root="${WEBROOTS[$i]}"
            escaped_root=$(nginx_escape "$root")
            # The dollar-prefixed names below are literal Nginx variables, not shell variables.
            # shellcheck disable=SC2016
            printf 'map $remote_user $pi_webdav_root_%s {\n' "$i"
            # shellcheck disable=SC2016
            printf '    default "%s/$remote_user/";\n' "$escaped_root"
            printf '    "%s" "%s/";\n' "$ADMIN_USER" "$escaped_root"
            printf '}\n\n'
        done
    } >"$tmp"
    install -m 644 "$tmp" "$MAP_FILE"
    rm -f "$tmp"
}

write_nginx_sites() {
    local i webroot port conf_name conf_file map_var sanitized_name

    for i in "${!WEBROOTS[@]}"; do
        webroot="${WEBROOTS[$i]}"
        port="${WEBDAV_PORTS[$i]}"
        sanitized_name=$(printf '%s' "$webroot" | tr -c '[:alnum:]' '_' | sed 's/_\+$//')
        [[ -n "$sanitized_name" ]] || sanitized_name="root${i}"
        conf_name="${SITE_PREFIX}${i}-${sanitized_name}.conf"
        conf_file="${SITE_AVAILABLE_DIR}/${conf_name}"
        map_var="\$pi_webdav_root_${i}"

        cat >"$conf_file" <<EOF_SITE
# Generated by ${PROJECT_NAME}. Do not edit manually.
server {
    listen ${port};
    listen [::]:${port};
    server_name _;

    access_log /var/log/nginx/pi-webdav-${i}-access.log;
    error_log /var/log/nginx/pi-webdav-error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level ${GZIP_LEVEL};
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml;

    location / {
        alias ${map_var};

        client_max_body_size ${MAX_UPLOAD_SIZE};
        auth_basic "WebDAV Restricted Area";
        auth_basic_user_file ${PASSFILE};
        autoindex ${AUTOINDEX_SETTING};

        dav_methods PUT DELETE MKCOL COPY MOVE;
        dav_ext_methods PROPFIND OPTIONS;
        create_full_put_path on;
        dav_access user:rw group:rw all:r;

        open_file_cache max=1000 inactive=30s;
        open_file_cache_valid 30s;
        open_file_cache_min_uses 2;
        open_file_cache_errors off;
    }
}
EOF_SITE
        chmod 644 "$conf_file"
        ln -sfn "$conf_file" "${SITE_ENABLED_DIR}/${conf_name}"
    done
}

write_management_script() {
    cat >"$MANAGEMENT_SCRIPT" <<'EOF_USERS'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/pi-webdav-nas/config"
readonly PASSFILE="/etc/nginx/pi-webdav.passwd"

fatal() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "run this command with sudo"
}

is_valid_username() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || fatal "${CONFIG_FILE} does not exist; run webdav_setup.sh install first"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

sync_user_dirs() {
    local user="$1"
    local root
    for root in "${WEBROOTS[@]}"; do
        mkdir -p "$root/$user"
        chown www-data:www-data "$root/$user"
        chmod 750 "$root/$user"
    done
}

usage() {
    cat <<'EOF_USAGE'
Usage: sudo pi-webdav-users <command> [username]

Commands:
  list                List configured WebDAV users
  add USER            Add a user and create a private directory in every WebDAV root
  passwd USER         Change a user's password
  del USER            Remove login access but preserve all user data
EOF_USAGE
}

main() {
    require_root
    load_config
    [[ -f "$PASSFILE" ]] || fatal "credentials file ${PASSFILE} does not exist"

    local command="${1:-}"
    local user="${2:-}"

    case "$command" in
        list)
            cut -d: -f1 "$PASSFILE"
            ;;
        add)
            [[ -n "$user" ]] || fatal "username is required"
            is_valid_username "$user" || fatal "invalid username"
            grep -Fq "${user}:" "$PASSFILE" && fatal "user '${user}' already exists"
            htpasswd "$PASSFILE" "$user"
            sync_user_dirs "$user"
            printf "User '%s' added.\n" "$user"
            ;;
        passwd)
            [[ -n "$user" ]] || fatal "username is required"
            is_valid_username "$user" || fatal "invalid username"
            grep -Fq "${user}:" "$PASSFILE" || fatal "user '${user}' does not exist"
            htpasswd "$PASSFILE" "$user"
            printf "Password updated for '%s'.\n" "$user"
            ;;
        del)
            [[ -n "$user" ]] || fatal "username is required"
            is_valid_username "$user" || fatal "invalid username"
            [[ "$user" != "${ADMIN_USER}" ]] || fatal "cannot delete the configured admin user; reconfigure the server first"
            grep -Fq "${user}:" "$PASSFILE" || fatal "user '${user}' does not exist"
            htpasswd -D "$PASSFILE" "$user" >/dev/null
            printf "User '%s' login removed. Data directories were preserved.\n" "$user"
            ;;
        *)
            usage
            [[ -n "$command" ]] && exit 1 || exit 0
            ;;
    esac
}

main "$@"
EOF_USERS
    chmod 755 "$MANAGEMENT_SCRIPT"
}

validate_nginx_and_reload() {
    log STEP "Validating Nginx configuration"
    nginx -t
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx
    log SUCCESS "Nginx configuration is valid and active."
}

install_or_apply() {
    install_packages
    ensure_password_file
    prepare_webroots

    install -d -m 755 "$SITE_AVAILABLE_DIR" "$SITE_ENABLED_DIR" "$(dirname "$MAP_FILE")"
    remove_managed_nginx_files
    write_nginx_map
    write_nginx_sites
    write_management_script
    validate_nginx_and_reload

    log HEADER "Setup complete"
    local i
    for i in "${!WEBROOTS[@]}"; do
        log SUCCESS "http://<SERVER_IP>:${WEBDAV_PORTS[$i]} -> ${WEBROOTS[$i]}"
    done
    log INFO "User management: sudo pi-webdav-users <list|add|passwd|del> [username]"
    log WARN "These endpoints use HTTP Basic Auth. Do NOT expose them directly to the Internet; use a trusted LAN/VPN or put HTTPS in front of them."
}

run_install() {
    require_root install
    if load_config; then
        log INFO "Existing configuration loaded from ${CONFIG_FILE}."
    else
        ask_for_settings
    fi
    install_or_apply
}

run_reconfigure() {
    require_root reconfigure
    load_config || true
    ask_for_settings
    install_or_apply
}

run_fresh() {
    require_root fresh
    load_config || true
    log WARN "Fresh mode recreates only ${PROJECT_NAME} configuration. WebDAV data and credentials are preserved."
    ask_for_settings
    remove_managed_nginx_files
    install_or_apply
}

run_reset() {
    require_root reset
    log HEADER "Remove Pi WebDAV NAS configuration"
    log WARN "Only files managed by ${PROJECT_NAME} will be removed. Nginx itself and WebDAV data will be preserved."
    local confirm=""
    read -r -p "Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { log INFO "Reset cancelled."; return 0; }

    remove_managed_nginx_files
    rm -f "$MANAGEMENT_SCRIPT"
    rm -f "$CONFIG_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true

    local remove_credentials=""
    read -r -p "Also remove saved WebDAV credentials? (y/N): " remove_credentials
    if [[ "$remove_credentials" =~ ^[yY]$ ]]; then
        rm -f "$PASSFILE"
        log INFO "Credentials removed."
    else
        log INFO "Credentials preserved at ${PASSFILE}."
    fi

    if command -v nginx >/dev/null 2>&1; then
        nginx -t
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        fi
    fi
    log SUCCESS "Pi WebDAV NAS configuration removed. User data was not touched."
}

root_backing_disks() {
    local source
    source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ -n "$source" && -b "$source" ]] || return 0
    lsblk -s -n -p -o NAME,TYPE "$source" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u
}

disk_has_mounted_children() {
    local disk="$1"
    lsblk -nrpo MOUNTPOINT "$disk" 2>/dev/null | grep -qE '^/.+'
}

run_raid_setup() {
    require_root raid
    log HEADER "RAID array setup"
    log WARN "This utility destroys all data on the selected disks. It intentionally refuses disks with mounted filesystems."

    install_packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y mdadm e2fsprogs >/dev/null

    [[ ! -e /dev/md0 ]] || fatal "/dev/md0 already exists. This script will not overwrite an existing RAID device."

    mapfile -t excluded_disks < <(root_backing_disks)
    mapfile -t all_disks < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')

    local available_disks=()
    local disk excluded skip
    for disk in "${all_disks[@]}"; do
        skip=false
        for excluded in "${excluded_disks[@]:-}"; do
            [[ "$disk" == "$excluded" ]] && skip=true
        done
        $skip && continue
        available_disks+=("$disk")
    done

    (( ${#available_disks[@]} > 0 )) || fatal "No non-root physical disks are available."

    log STEP "Available non-root disks:"
    local i
    for i in "${!available_disks[@]}"; do
        disk="${available_disks[$i]}"
        printf '  %d) %s\n' "$((i + 1))" "$(lsblk -dno NAME,SIZE,MODEL "$disk" | xargs)"
    done

    local selected_disks=()
    while true; do
        local choice=""
        read -r -p "Select a disk number, or type 'done': " choice
        [[ "$choice" == "done" ]] && break
        [[ "$choice" =~ ^[0-9]+$ ]] || { log WARN "Enter a listed number or 'done'."; continue; }
        (( choice >= 1 && choice <= ${#available_disks[@]} )) || { log WARN "Invalid disk number."; continue; }
        disk="${available_disks[$((choice - 1))]}"

        if disk_has_mounted_children "$disk"; then
            log WARN "${disk} has mounted filesystems. Unmount them before using this RAID utility."
            continue
        fi
        if printf '%s\n' "${selected_disks[@]:-}" | grep -Fxq "$disk"; then
            log WARN "${disk} is already selected."
            continue
        fi
        if wipefs -n "$disk" 2>/dev/null | grep -q .; then
            log WARN "${disk} contains an existing filesystem/partition/RAID signature. It will be destroyed if you continue."
        fi
        selected_disks+=("$disk")
        log SUCCESS "Selected ${disk}."
    done

    (( ${#selected_disks[@]} >= 2 )) || fatal "Select at least two disks."

    local raid_level=""
    while true; do
        read -r -p "RAID level (0, 1, or 5): " raid_level
        [[ "$raid_level" =~ ^(0|1|5)$ ]] || { log WARN "Choose RAID 0, 1, or 5."; continue; }
        [[ "$raid_level" != "5" || ${#selected_disks[@]} -ge 3 ]] || { log WARN "RAID 5 requires at least three disks."; continue; }
        break
    done

    local mount_point=""
    while true; do
        read -r -p "Mount point for /dev/md0 (example: /srv/raid): " mount_point
        mount_point=$(normalize_webroot "$mount_point")
        is_safe_webroot "$mount_point" || { log WARN "Choose a dedicated absolute mount point."; continue; }
        if [[ -d "$mount_point" && -n "$(find "$mount_point" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            log WARN "Mount point ${mount_point} is not empty. Choose an empty directory."
            continue
        fi
        break
    done

    log HEADER "Final destructive confirmation"
    log ERROR "Selected disks: ${selected_disks[*]}"
    log ERROR "ALL DATA AND SIGNATURES ON THESE DISKS WILL BE DESTROYED."
    local confirm=""
    read -r -p "Type ERASE to create RAID ${raid_level} on /dev/md0: " confirm
    [[ "$confirm" == "ERASE" ]] || { log INFO "RAID creation cancelled."; return 0; }

    mdadm --create /dev/md0 --level="$raid_level" --raid-devices="${#selected_disks[@]}" "${selected_disks[@]}" --run
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle || true
    fi
    [[ -b /dev/md0 ]] || fatal "/dev/md0 was not created successfully."

    mkfs.ext4 -F /dev/md0
    mkdir -p "$mount_point"

    local uuid
    uuid=$(blkid -s UUID -o value /dev/md0)
    [[ -n "$uuid" ]] || fatal "Could not read UUID for /dev/md0."
    if ! grep -Fq "UUID=${uuid} " /etc/fstab; then
        printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$mount_point" >>/etc/fstab
    fi

    local mdadm_line
    mdadm_line=$(mdadm --detail --scan | grep '/dev/md0' | head -n1 || true)
    if [[ -n "$mdadm_line" ]]; then
        install -d -m 755 /etc/mdadm
        touch /etc/mdadm/mdadm.conf
        grep -Fxq "$mdadm_line" /etc/mdadm/mdadm.conf || printf '%s\n' "$mdadm_line" >>/etc/mdadm/mdadm.conf
    fi
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u || true
    fi

    mount "$mount_point"
    log SUCCESS "RAID ${raid_level} created at /dev/md0 and mounted on ${mount_point}."
    log WARN "RAID is not a backup. Keep separate backups of important data."
}

usage() {
    cat <<'EOF_USAGE'
Usage: sudo ./webdav_setup.sh [command]

Commands:
  install       Install/apply the saved configuration. If no config exists, start interactive setup.
  reconfigure   Change WebDAV locations/global settings, then apply them.
  fresh         Recreate only Pi WebDAV NAS configuration; preserve credentials and user data.
  reset         Remove only Pi WebDAV NAS configuration; preserve Nginx and user data.
  raid          Interactively create a new /dev/md0 software RAID array.
  help          Show this help.

Running with no command is the same as 'install'.
EOF_USAGE
}

main() {
    local command="${1:-install}"
    case "$command" in
        install) run_install ;;
        reconfigure) run_reconfigure ;;
        fresh) run_fresh ;;
        reset) run_reset ;;
        raid) run_raid_setup ;;
        help|-h|--help) usage ;;
        *) usage; fatal "Unknown command: ${command}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
