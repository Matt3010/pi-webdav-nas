#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../webdav_setup.sh
source "$ROOT_DIR/webdav_setup.sh"

failures=0

expect_true() {
    local description="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$description"
    else
        printf 'not ok - %s\n' "$description"
        failures=$((failures + 1))
    fi
}

expect_false() {
    local description="$1"
    shift
    if "$@"; then
        printf 'not ok - %s\n' "$description"
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$description"
    fi
}

expect_true "valid username" is_valid_username "matteo-01.test"
expect_false "username cannot start with dot" is_valid_username ".hidden"
expect_false "username rejects slash" is_valid_username "a/b"
expect_true "port 1 is valid" is_valid_port "1"
expect_true "port 65535 is valid" is_valid_port "65535"
expect_false "port 0 is invalid" is_valid_port "0"
expect_false "port 65536 is invalid" is_valid_port "65536"
expect_false "non-numeric port is invalid" is_valid_port "abc"
expect_true "100M is a valid upload size" is_valid_size "100M"
expect_true "0 is a valid upload size" is_valid_size "0"
expect_false "invalid upload size is rejected" is_valid_size "2GB"
expect_true "dedicated /srv path is safe" is_safe_webroot "/srv/webdav"
expect_true "nested /mnt path is safe" is_safe_webroot "/mnt/storage/webdav"
expect_false "root filesystem is blocked" is_safe_webroot "/"
expect_false "top-level /etc is blocked" is_safe_webroot "/etc"
expect_false "relative path is blocked" is_safe_webroot "srv/webdav"

if grep -Eq 'chown[[:space:]]+-R|chmod[[:space:]]+-R' "$ROOT_DIR/webdav_setup.sh"; then
    printf 'not ok - script must not recursively chown/chmod WebDAV data\n'
    failures=$((failures + 1))
else
    printf 'ok - no recursive chown/chmod of WebDAV data\n'
fi

if grep -Eq 'apt-get[[:space:]].*(purge|remove).*nginx|rm[[:space:]]+-rf[[:space:]]+/etc/nginx' "$ROOT_DIR/webdav_setup.sh"; then
    printf 'not ok - script must not purge unrelated Nginx configuration\n'
    failures=$((failures + 1))
else
    printf 'ok - no destructive global Nginx cleanup\n'
fi

if grep -Fq 'map $remote_user $pi_webdav_root_' "$ROOT_DIR/webdav_setup.sh"; then
    printf 'ok - user routing uses an Nginx map\n'
else
    printf 'not ok - user routing must use an Nginx map\n'
    failures=$((failures + 1))
fi

exit "$failures"
