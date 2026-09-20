#!/usr/bin/env bash
# Mounts a raw Raspberry Pi OS .img file via a loop device, chroots into its
# root filesystem, and runs a hook script inside it. Use this to preinstall
# packages, drop config files, enable services, etc. before flashing the
# image to an SD card.
#
# Usage:
#   sudo ./customize_image.sh [--grow-mb N] <image.img> <hook-script> [-- hook-args...]
#
# Raspberry Pi OS images ship with their root filesystem sized tight to their
# content (a first-boot service normally expands it to fill the SD card) -
# there's rarely more than a few hundred MB of free space to install
# anything into. --grow-mb N grows the image file to N MiB (only ever up,
# never shrinks an already-larger file) and resizes the root partition +
# ext4 filesystem to fill the new space, before mounting/running the hook.
#
# The hook script is copied into the chroot and executed as /tmp/customize.sh
# with the working directory set to the root of the mounted image. It runs
# as root, "inside" the Raspberry Pi's filesystem (via qemu-user-static, if
# the image architecture doesn't match the host).
#
# This repo (the directory this script lives in) is also bind-mounted
# read-only inside the chroot at /mnt/host-repo, so a hook script can pull in
# local sources (e.g. modules/dmod) without needing network/git credentials
# inside the chroot.
#
# Requires: losetup, mount, chroot (util-linux), and - when flashing an ARM
# image from an x86_64 host - the qemu-user-static package (for
# qemu-aarch64-static / qemu-arm-static) with binfmt_misc registered.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (it uses losetup/mount/chroot)." >&2
    exit 1
fi

GROW_MB=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --grow-mb)
            GROW_MB="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [--grow-mb N] <image.img> <hook-script> [-- hook-args...]" >&2
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

RESIZE_NEEDED=0
if [[ "$GROW_MB" -gt 0 ]]; then
    CURRENT_BYTES="$(stat -c%s "$IMAGE")"
    TARGET_BYTES=$(( GROW_MB * 1024 * 1024 ))
    if (( TARGET_BYTES > CURRENT_BYTES )); then
        echo "Growing $IMAGE to ${GROW_MB}MiB for customization headroom..."
        truncate -s "$TARGET_BYTES" "$IMAGE"
        RESIZE_NEEDED=1
    else
        echo "$IMAGE is already >= ${GROW_MB}MiB, no growth needed."
    fi
fi

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

if [[ "$RESIZE_NEEDED" -eq 1 ]]; then
    echo "Resizing root partition and filesystem to use the new space..."
    command -v parted >/dev/null || { echo "parted not found - install it (sudo apt install parted) to use --grow-mb." >&2; exit 1; }
    command -v resize2fs >/dev/null || { echo "resize2fs not found - install it (sudo apt install e2fsprogs) to use --grow-mb." >&2; exit 1; }
    parted -s "$LOOP" resizepart 2 100%
    partprobe "$LOOP" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    e2fsck -f -p "$ROOT_PART" || true
    resize2fs "$ROOT_PART"
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

echo "Bind-mounting repo ($SCRIPT_DIR) read-only at /mnt/host-repo..."
mkdir -p "$MNT/mnt/host-repo"
mount --bind "$SCRIPT_DIR" "$MNT/mnt/host-repo"
mount -o remount,ro,bind "$MNT/mnt/host-repo"
MOUNTED+=("$MNT/mnt/host-repo")

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
