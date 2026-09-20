#!/usr/bin/env bash
# Tier: mini - the smallest customization, and the one that always runs
# immediately (in the chroot, at image-prep time on the host). It enables
# SSH, optionally configures Wi-Fi and a login user, and - when a heavier
# tier is requested - stages that tier's source/scripts on the image and
# schedules it to run natively on the Pi's own CPU the first time it boots
# for real (via a oneshot systemd service), instead of running the heavy
# build here under qemu-user-static emulation. That's both much faster and
# avoids network flakiness inside the emulated chroot.
#
# Usage:
#   mini.sh [--wifi-ssid SSID --wifi-country CC [--wifi-password PASS]]
#           [--username USER --password PASS]
#           [--defer-tier basic|full]
#
# Run via prepare_rpi_sd.py --customize mini (or ...--customize basic/full,
# which passes --defer-tier through), or standalone:
#   sudo ./customize_image.sh <image.img> customize-scripts/mini.sh -- [options...]

set -euo pipefail

WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_COUNTRY=""
USERNAME=""
PASSWORD=""
DEFER_TIER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wifi-ssid)     WIFI_SSID="$2"; shift 2 ;;
        --wifi-password) WIFI_PASSWORD="$2"; shift 2 ;;
        --wifi-country)  WIFI_COUNTRY="$2"; shift 2 ;;
        --username)      USERNAME="$2"; shift 2 ;;
        --password)      PASSWORD="$2"; shift 2 ;;
        --defer-tier)    DEFER_TIER="$2"; shift 2 ;;
        *) echo "mini.sh: unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$WIFI_SSID" && -z "$WIFI_COUNTRY" ]]; then
    echo "mini.sh: --wifi-country is required when --wifi-ssid is given (the wifi radio may stay blocked without a regulatory domain)." >&2
    exit 1
fi
if [[ ( -n "$USERNAME" && -z "$PASSWORD" ) || ( -z "$USERNAME" && -n "$PASSWORD" ) ]]; then
    echo "mini.sh: --username and --password must be given together." >&2
    exit 1
fi
if [[ -n "$DEFER_TIER" && "$DEFER_TIER" != "basic" && "$DEFER_TIER" != "full" ]]; then
    echo "mini.sh: --defer-tier must be 'basic' or 'full', got: $DEFER_TIER" >&2
    exit 1
fi

if [[ -d /boot/firmware ]]; then
    BOOT_DIR=/boot/firmware
else
    BOOT_DIR=/boot
fi

# --------------------------------------------------------------------------
# SSH (sshswitch.service enables + starts ssh.service on boot when this
# empty file is present on the boot partition, then deletes it)
# --------------------------------------------------------------------------

echo "==> Enabling SSH"
touch "$BOOT_DIR/ssh"

# --------------------------------------------------------------------------
# Wi-Fi (a plain NetworkManager keyfile connection profile - Raspberry Pi
# OS has used NetworkManager as its network stack since Bookworm)
# --------------------------------------------------------------------------

if [[ -n "$WIFI_SSID" ]]; then
    echo "==> Setting Wi-Fi country to $WIFI_COUNTRY"
    raspi-config nonint do_wifi_country "$WIFI_COUNTRY"

    echo "==> Configuring Wi-Fi network '$WIFI_SSID'"
    NM_DIR=/etc/NetworkManager/system-connections
    mkdir -p "$NM_DIR"
    CONN_UUID="$(cat /proc/sys/kernel/random/uuid)"
    CONN_FILE="$NM_DIR/preconfigured.nmconnection"

    {
        echo "[connection]"
        echo "id=preconfigured"
        echo "uuid=$CONN_UUID"
        echo "type=wifi"
        echo "autoconnect=true"
        echo
        echo "[wifi]"
        echo "mode=infrastructure"
        echo "ssid=$WIFI_SSID"
        echo
        if [[ -n "$WIFI_PASSWORD" ]]; then
            echo "[wifi-security]"
            echo "key-mgmt=wpa-psk"
            echo "psk=$WIFI_PASSWORD"
            echo
        fi
        echo "[ipv4]"
        echo "method=auto"
        echo
        echo "[ipv6]"
        echo "method=auto"
        echo "addr-gen-mode=default"
        echo
        echo "[proxy]"
    } > "$CONN_FILE"
    chmod 600 "$CONN_FILE"
fi

# --------------------------------------------------------------------------
# Login user (plain useradd/chpasswd - works whether or not the image ships
# a default user, and doesn't depend on any first-boot tooling to run)
# --------------------------------------------------------------------------

if [[ -n "$USERNAME" ]]; then
    echo "==> Creating user '$USERNAME'"
    if id "$USERNAME" &>/dev/null; then
        echo "    User $USERNAME already exists, just setting the password."
    else
        useradd -m -s /bin/bash -G sudo "$USERNAME"
    fi
    echo "$USERNAME:$PASSWORD" | chpasswd
else
    if [[ -f "$BOOT_DIR/ssh" ]]; then
        echo "==> WARNING: SSH is enabled but no --username/--password was given -" >&2
        echo "    this image may not have any usable login account." >&2
    fi
fi

# --------------------------------------------------------------------------
# Defer a heavier tier to the Pi's own first real boot (native, no qemu)
# --------------------------------------------------------------------------

if [[ -n "$DEFER_TIER" ]]; then
    HOST_REPO=/mnt/host-repo
    if [[ ! -d "$HOST_REPO/customize-scripts" ]]; then
        echo "Expected $HOST_REPO/customize-scripts (repo bind-mount) - is this being run via customize_image.sh?" >&2
        exit 1
    fi
    source "$HOST_REPO/customize-scripts/common/paths.sh"

    echo "==> Staging dmod source for the deferred '$DEFER_TIER' setup"
    rm -rf "$SRC_DIR/dmod"
    mkdir -p "$SRC_DIR/dmod"
    cp -a "$HOST_REPO/modules/dmod/." "$SRC_DIR/dmod/"
    rm -rf "$SRC_DIR/dmod/build"

    if [[ "$DEFER_TIER" == "full" && -d "$HOST_REPO/modules/dmboot" ]]; then
        echo "==> Staging dmod-boot source for the deferred 'full' setup"
        rm -rf "$SRC_DIR/dmod-boot"
        mkdir -p "$SRC_DIR/dmod-boot"
        cp -a "$HOST_REPO/modules/dmboot/." "$SRC_DIR/dmod-boot/"
        rm -rf "$SRC_DIR/dmod-boot/build"
    fi

    echo "==> Staging customize-scripts for the deferred '$DEFER_TIER' setup"
    STAGED_SCRIPTS_DIR="$SRC_DIR/customize-scripts"
    rm -rf "$STAGED_SCRIPTS_DIR"
    mkdir -p "$STAGED_SCRIPTS_DIR"
    cp -a "$HOST_REPO/customize-scripts/." "$STAGED_SCRIPTS_DIR/"
    chmod +x "$STAGED_SCRIPTS_DIR"/*.sh

    echo "==> Installing dmod-first-boot.service (runs $DEFER_TIER.sh on first real boot)"
    cat > /etc/systemd/system/dmod-first-boot.service <<EOF
[Unit]
Description=DMOD first-boot environment setup ($DEFER_TIER)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/dmod-first-boot.done

[Service]
Type=oneshot
ExecStart=$STAGED_SCRIPTS_DIR/$DEFER_TIER.sh
ExecStartPost=/bin/sh -c 'touch /var/lib/dmod-first-boot.done'
ExecStartPost=/bin/sh -c 'systemctl disable dmod-first-boot.service || true'
StandardOutput=append:/var/log/dmod-first-boot.log
StandardError=append:/var/log/dmod-first-boot.log
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/dmod-first-boot.service \
        /etc/systemd/system/multi-user.target.wants/dmod-first-boot.service

    echo "==> '$DEFER_TIER' will run automatically on first boot; check progress with:"
    echo "      journalctl -u dmod-first-boot -f"
    echo "    or:"
    echo "      tail -f /var/log/dmod-first-boot.log"
fi

echo "==> Done"
