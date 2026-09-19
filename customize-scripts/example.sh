#!/usr/bin/env bash
# Example hook script for customize_image.sh / prepare_rpi_sd.py --customize-script.
#
# This runs *inside a chroot* of the mounted image's root filesystem, as
# root, before the image is flashed to the SD card. Copy this file, edit it
# to suit your needs, and point --customize-script at your copy.

set -euo pipefail

echo "==> Enabling SSH on first boot"
touch /boot/firmware/ssh 2>/dev/null || touch /boot/ssh

echo "==> Setting hostname"
echo "my-rpi" > /etc/hostname
sed -i 's/127.0.1.1.*/127.0.1.1\tmy-rpi/' /etc/hosts

echo "==> Updating package lists and installing extra packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends git vim

echo "==> Done"
