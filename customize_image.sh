#!/usr/bin/env bash
# Mounts a raw Raspberry Pi OS .img file via a loop device, chroots into its
# root filesystem, and runs a hook script inside it. Use this to preinstall
# packages, drop config files, enable services, etc. before flashing the
# image to an SD card.
#
# Usage:
#   sudo ./customize_image.sh <image.img> <hook-script> [-- hook-args...]
#
# The hook script is copied into the chroot and executed as /tmp/customize.sh
# with the working directory set to the root of the mounted image. It runs
# as root, "inside" the Raspberry Pi's filesystem (via qemu-user-static, if
# the image architecture doesn't match the host).
#
# Requires: losetup, mount, chroot (util-linux), and - when flashing an ARM
# image from an x86_64 host - the qemu-user-static package (for
# qemu-aarch64-static / qemu-arm-static) with binfmt_misc registered.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (it uses losetup/mount/chroot)." >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <image.img> <hook-script> [-- hook-args...]" >&2
    exit 1
fi

IMAGE="$1"
HOOK="$2"
shift 2
if [[ "${1:-}" == "--" ]]; then
    shift
fi
HOOK_ARGS=("$@")

if [[ ! -f "$IMAGE" ]]; then
    echo "Image not found: $IMAGE" >&2
    exit 1
fi
if [[ ! -f "$HOOK" ]]; then
    echo "Hook script not found: $HOOK" >&2
    exit 1
fi

LOOP=""
MNT=""
BOOT_MP=""
QEMU_COPIED=""
RESOLV_BACKED_UP=0
MOUNTED=()  # mount points, in the order they were mounted (unmounted in reverse)

cleanup() {
    local mp
    if [[ -n "$MNT" ]]; then
        rm -f "$MNT/tmp/customize.sh" 2>/dev/null || true
        if [[ -n "$QEMU_COPIED" ]]; then
            rm -f "$MNT$QEMU_COPIED" 2>/dev/null || true
        fi
        if [[ $RESOLV_BACKED_UP -eq 1 ]]; then
            mv -f "$MNT/etc/resolv.conf.customize-bak" "$MNT/etc/resolv.conf" 2>/dev/null || true
        fi
    fi

    for (( idx=${#MOUNTED[@]}-1 ; idx>=0 ; idx-- )); do
        mp="${MOUNTED[idx]}"
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    done

    if [[ -n "$LOOP" ]]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    if [[ -n "$MNT" && -d "$MNT" ]]; then
        rmdir "$MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Attaching $IMAGE as a loop device..."
LOOP="$(losetup --find --show -P "$IMAGE")"

# Give the kernel a moment to expose the partition devices.
udevadm settle 2>/dev/null || true
for _ in $(seq 1 20); do
    [[ -e "${LOOP}p1" && -e "${LOOP}p2" ]] && break
    sleep 0.5
done

BOOT_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"
if [[ ! -e "$BOOT_PART" || ! -e "$ROOT_PART" ]]; then
    echo "Could not find partitions ${BOOT_PART} / ${ROOT_PART} on $LOOP." >&2
    echo "Is this a standard Raspberry Pi OS image (boot + root partition)?" >&2
    exit 1
fi

MNT="$(mktemp -d /tmp/rpi-sd-customize.XXXXXX)"
echo "Mounting root partition ($ROOT_PART) at $MNT..."
mount "$ROOT_PART" "$MNT"
MOUNTED+=("$MNT")

if [[ -d "$MNT/boot/firmware" ]]; then
    BOOT_MP="$MNT/boot/firmware"
else
    BOOT_MP="$MNT/boot"
fi
echo "Mounting boot partition ($BOOT_PART) at $BOOT_MP..."
mount "$BOOT_PART" "$BOOT_MP"
MOUNTED+=("$BOOT_MP")

mount --bind /dev "$MNT/dev"
MOUNTED+=("$MNT/dev")
mount --bind /dev/pts "$MNT/dev/pts"
MOUNTED+=("$MNT/dev/pts")
mount -t proc proc "$MNT/proc"
MOUNTED+=("$MNT/proc")
mount -t sysfs sysfs "$MNT/sys"
MOUNTED+=("$MNT/sys")

# Give the chroot working DNS resolution (needed for apt-get, curl, etc.).
if [[ -f "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
    mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.customize-bak"
    RESOLV_BACKED_UP=1
fi
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

# If the image's architecture doesn't match the host, register a static
# qemu binary so `chroot` can execute the target's binaries. This assumes
# qemu-user-static + binfmt_misc are already installed/registered on the
# host (standard on Debian/Ubuntu: `apt install qemu-user-static binfmt-support`).
TARGET_MACHINE="$(readelf -h "$MNT/bin/bash" 2>/dev/null | awk -F': *' '/Machine:/ {print $2}')"
HOST_MACHINE="$(uname -m)"
QEMU_BIN=""
case "$TARGET_MACHINE" in
    AArch64) [[ "$HOST_MACHINE" != "aarch64" ]] && QEMU_BIN="qemu-aarch64-static" ;;
    "ARM")   [[ "$HOST_MACHINE" != "arm"* ]] && QEMU_BIN="qemu-arm-static" ;;
esac

if [[ -n "$QEMU_BIN" ]]; then
    QEMU_SRC="$(command -v "$QEMU_BIN" || true)"
    if [[ -z "$QEMU_SRC" ]]; then
        echo "This is a $TARGET_MACHINE image but $QEMU_BIN was not found on the host." >&2
        echo "Install it first, e.g.: sudo apt install qemu-user-static binfmt-support" >&2
        exit 1
    fi
    QEMU_COPIED="/usr/bin/$QEMU_BIN"
    cp "$QEMU_SRC" "$MNT$QEMU_COPIED"
fi

cp "$HOOK" "$MNT/tmp/customize.sh"
chmod +x "$MNT/tmp/customize.sh"

echo "Running hook script inside the chroot..."
chroot "$MNT" /tmp/customize.sh "${HOOK_ARGS[@]}"

echo "Customization finished successfully."
