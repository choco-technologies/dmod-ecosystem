#!/usr/bin/env bash
# Tier: full - the complete DMOD development environment, equivalent to
# chocotechnologies/dmod:1.0.4 plus the Renode/dmffs tooling from
# dmod-boot's dev image and the Claude Code CLI - so dmod and its modules
# can be built and debugged directly on the Raspberry Pi. Builds on top of
# the "basic" tier (which itself includes "mini").
#
# It mirrors, in order:
#   - customize-scripts/basic.sh              (mini + build tools + dmod itself)
#   - modules/dmod/Docker/Dockerfile.env      (embedded toolchains)
#   - modules/dmboot/docker/Dockerfile.env    (Renode + extra packages + dmffs)
#   - modules/dmboot/scripts/setup-linux-env.sh (libgtk2.0 fallback, dmffs alias)
#   - modules/dmod/Docker/Dockerfile.claude   (Node.js + Claude Code CLI)
#
# Runs in one of two contexts - see basic.sh's header for details:
#   - image-prep time, in the chroot via customize_image.sh (bind-mounts
#     this repo read-only at /mnt/host-repo) - direct invocation.
#   - natively on the Pi's own first real boot, from a pre-staged copy - what
#     `prepare_rpi_sd.py --customize full` actually sets up.

set -euo pipefail

HOST_REPO=/mnt/host-repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$HOST_REPO/customize-scripts" ]]; then
    CUSTOMIZE_SCRIPTS_DIR="$HOST_REPO/customize-scripts"
else
    CUSTOMIZE_SCRIPTS_DIR="$SCRIPT_DIR"
fi
source "$CUSTOMIZE_SCRIPTS_DIR/common/paths.sh"

echo "==> Running basic tier (build & install dmod)"
bash "$CUSTOMIZE_SCRIPTS_DIR/basic.sh"

# basic.sh ran as a separate process, so its env vars don't carry over here -
# re-export the same (fixed) paths from common/paths.sh instead.
export DEBIAN_FRONTEND=noninteractive
export DMOD_DMF_DIR
export DMOD_DMFC_DIR
export PATH="$PATH:/usr/local/bin"

case "$(uname -m)" in
    x86_64)          HOST_ARCH=x86_64 ;;
    aarch64|arm64)   HOST_ARCH=aarch64 ;;
    *)
        echo "Unsupported host architecture: $(uname -m)" >&2
        exit 1
        ;;
esac
echo "==> Target architecture inside the image: $HOST_ARCH"

# Installs the first available alternative from a list of candidate package
# name(s) (space-separated within one candidate, for packages that were
# split in two, e.g. "polkitd pkexec"). Package names/availability drift
# between Debian releases (Bullseye/Bookworm/Trixie), which is what Raspberry
# Pi OS is based on - a single hardcoded name breaks `apt-get install` for
# the *whole* batch on newer/older releases.
apt_install_alt() {
    local candidate
    for candidate in "$@"; do
        # Try the actual install rather than pre-checking with `apt-cache
        # show`: transitional/dummy packages (e.g. old policykit-1 on
        # Bookworm+) still show up there with no installable candidate.
        if apt-get install -y --no-install-recommends $candidate 2>/dev/null; then
            return 0
        fi
    done
    echo "    Warning: none of [$*] are installable, skipping." >&2
}

# --------------------------------------------------------------------------
# 1. Extra base packages, on top of "basic" (modules/dmboot/docker/Dockerfile.env)
# --------------------------------------------------------------------------

echo "==> Installing extra dmod-boot packages"
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates gnupg xz-utils \
    screen uml-utilities libc6-dev \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf

# Packages whose name/availability drifted across Debian releases - see
# modules/dmboot/scripts/setup-linux-env.sh for the same libgtk2.0 fallback.
apt_install_alt libncurses5 libncurses6                  # legacy ncurses ABI, if present
apt_install_alt policykit-1 "polkitd pkexec"              # split into polkitd+pkexec since Bookworm
apt_install_alt libgtk2.0-0 libgtk2.0-0t64                # renamed for the 64-bit time_t transition

mkdir -p "$TOOLS_DIR"

# --------------------------------------------------------------------------
# 2. arm-none-eabi toolchain (modules/dmod/Docker/Dockerfile.env)
# --------------------------------------------------------------------------

ARM_NONE_EABI_VERSION=13.3.rel1
ARM_NONE_EABI_DIR_NAME=arm-gnu-toolchain
ARM_NONE_EABI_FILE_NAME="$ARM_NONE_EABI_DIR_NAME-$ARM_NONE_EABI_VERSION-$HOST_ARCH-arm-none-eabi.tar.xz"
ARM_NONE_EABI_URL="https://developer.arm.com/-/media/Files/downloads/gnu/$ARM_NONE_EABI_VERSION/binrel/$ARM_NONE_EABI_FILE_NAME"
ARM_NONE_EABI_DIR_PATH="$TOOLS_DIR/$ARM_NONE_EABI_DIR_NAME"

echo "==> Installing arm-none-eabi toolchain ($ARM_NONE_EABI_VERSION, $HOST_ARCH)"
wget -q "$ARM_NONE_EABI_URL" -O "$TOOLS_DIR/$ARM_NONE_EABI_FILE_NAME"
tar xf "$TOOLS_DIR/$ARM_NONE_EABI_FILE_NAME" -C "$TOOLS_DIR"
rm -f "$TOOLS_DIR/$ARM_NONE_EABI_FILE_NAME"
mv "$TOOLS_DIR/$ARM_NONE_EABI_DIR_NAME-$ARM_NONE_EABI_VERSION-$HOST_ARCH-arm-none-eabi" "$ARM_NONE_EABI_DIR_PATH"

# --------------------------------------------------------------------------
# 3. Xtensa (ESP32) toolchain + ESP-IDF (modules/dmod/Docker/Dockerfile.env)
# --------------------------------------------------------------------------

XTENSA_ESP_VERSION=14.2.0_20260121
XTENSA_ESP_DIR_NAME=xtensa-esp-elf
XTENSA_ESP_FILE_NAME="$XTENSA_ESP_DIR_NAME-$XTENSA_ESP_VERSION-$HOST_ARCH-linux-gnu.tar.xz"
XTENSA_ESP_DIR_PATH="$TOOLS_DIR/$XTENSA_ESP_DIR_NAME"

echo "==> Installing Xtensa ESP toolchain ($XTENSA_ESP_VERSION, $HOST_ARCH)"
wget -q "https://github.com/espressif/crosstool-NG/releases/download/esp-$XTENSA_ESP_VERSION/$XTENSA_ESP_FILE_NAME" \
    -O "$TOOLS_DIR/$XTENSA_ESP_FILE_NAME"
tar xf "$TOOLS_DIR/$XTENSA_ESP_FILE_NAME" -C "$TOOLS_DIR"
rm -f "$TOOLS_DIR/$XTENSA_ESP_FILE_NAME"
XTENSA_ESP_SRC_DIR="$(find "$TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d \( -name 'xtensa-esp-elf*' -o -name 'xtensa-esp32*' \) | head -n 1)"
if [[ -n "$XTENSA_ESP_SRC_DIR" && "$XTENSA_ESP_SRC_DIR" != "$XTENSA_ESP_DIR_PATH" ]]; then
    mv "$XTENSA_ESP_SRC_DIR" "$XTENSA_ESP_DIR_PATH"
fi

export PATH="$PATH:$ARM_NONE_EABI_DIR_PATH/bin:$XTENSA_ESP_DIR_PATH/bin"

echo "==> Installing ESP-IDF"
ESP_IDF_VERSION=v5.2.2
IDF_TOOLS_PATH="$TOOLS_DIR/.espressif"
IDF_PATH="$TOOLS_DIR/esp-idf"
git clone --recursive --branch "$ESP_IDF_VERSION" https://github.com/espressif/esp-idf.git "$IDF_PATH"
IDF_TOOLS_PATH="$IDF_TOOLS_PATH" "$IDF_PATH/install.sh" esp32s3

# --------------------------------------------------------------------------
# 4. Renode (modules/dmboot/docker/Dockerfile.env) - x86_64 only, Renode
#    doesn't ship arm64 .deb packages; on a real Pi you debug real hardware
#    via OpenOCD instead, so this is skipped rather than failing the build.
# --------------------------------------------------------------------------

if [[ "$HOST_ARCH" == "x86_64" ]]; then
    echo "==> Installing Renode"
    RENODE_VERSION=1.15.3
    wget -q "https://github.com/renode/renode/releases/download/v${RENODE_VERSION}/renode_${RENODE_VERSION}_amd64.deb" \
        -O /tmp/renode.deb
    dpkg -i /tmp/renode.deb || apt-get install -f -y
    rm -f /tmp/renode.deb
else
    echo "==> Skipping Renode (no $HOST_ARCH package available; use OpenOCD with real hardware instead)"
fi

# --------------------------------------------------------------------------
# 5. cmake (modules/dmod/Docker/Dockerfile.env pins a specific version;
#    the apt package installed by basic.sh is a reasonable fallback here)
# --------------------------------------------------------------------------

CMAKE_VERSION=3.31.3
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-linux-$HOST_ARCH.sh"
echo "==> Installing pinned CMake $CMAKE_VERSION"
if wget -q "$CMAKE_URL" -O /tmp/cmake.sh; then
    chmod +x /tmp/cmake.sh
    /tmp/cmake.sh --skip-license --prefix=/usr
    rm -f /tmp/cmake.sh
else
    echo "    Pinned CMake $CMAKE_VERSION ($HOST_ARCH) not available, keeping the apt package." >&2
fi

# --------------------------------------------------------------------------
# 6. dmffs (modules/dmboot/docker/Dockerfile +
#    modules/dmboot/scripts/setup-linux-env.sh) - fetched via dmf-get, which
#    basic.sh already built and installed. Best-effort: don't fail the whole
#    customization if the module registry isn't reachable from here. Also
#    retried a few times - dmf-get has a confirmed intermittent segfault when
#    run non-interactively (see basic.sh's comment on DMOD_BUILD_EXAMPLES),
#    and empirically often succeeds on a subsequent attempt.
# --------------------------------------------------------------------------

echo "==> Installing dmffs (dmf-get make_dmffs)"
DMFFS_OK=0
for attempt in 1 2 3; do
    if dmf-get make_dmffs --type dmf; then
        DMFFS_OK=1
        break
    fi
    echo "    dmf-get make_dmffs failed (attempt $attempt/3) - retrying..." >&2
done
if [[ "$DMFFS_OK" -eq 1 ]]; then
    echo "alias make_dmffs='dmod_loader \${DMOD_DMF_DIR}/make_dmffs.dmf --args'" >> /etc/bash.bashrc
else
    echo "    Warning: 'dmf-get make_dmffs' failed after 3 attempts - skipping." >&2
fi

# --------------------------------------------------------------------------
# 7. dmod-boot source, as an editable starting point (not built here - it's
#    firmware, built per-target once you're on the board).
# --------------------------------------------------------------------------

if [[ -d "$HOST_REPO/modules/dmboot" ]]; then
    echo "==> Copying dmod-boot source to $SRC_DIR/dmod-boot"
    # See the same rm+mkdir+cp -a "src/." pattern in basic.sh - the working
    # .img is reused across runs, and `cp -a` doesn't overwrite an existing
    # directory, it nests into it.
    rm -rf "$SRC_DIR/dmod-boot"
    mkdir -p "$SRC_DIR/dmod-boot"
    cp -a "$HOST_REPO/modules/dmboot/." "$SRC_DIR/dmod-boot/"
    rm -rf "$SRC_DIR/dmod-boot/build"
elif [[ -d "$SRC_DIR/dmod-boot" ]]; then
    echo "==> Using pre-staged dmod-boot source at $SRC_DIR/dmod-boot"
else
    echo "==> No dmod-boot source available (no host-repo bind-mount and nothing pre-staged) - skipping"
fi

# --------------------------------------------------------------------------
# 8. Node.js + Claude Code CLI (modules/dmod/Docker/Dockerfile.claude)
# --------------------------------------------------------------------------

echo "==> Installing Node.js and the Claude Code CLI"
NODE_MAJOR=20
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs ripgrep
npm install -g @anthropic-ai/claude-code

# --------------------------------------------------------------------------
# 9. Wire up PATH / env vars for every login shell
# --------------------------------------------------------------------------

echo "==> Writing /etc/profile.d/dmod-dev.sh"
cat > /etc/profile.d/dmod-dev.sh <<EOF
# Added by customize-scripts/full.sh (extends basic.sh's version)
export DMOD_DMF_DIR=$DMOD_DMF_DIR
export DMOD_DMFC_DIR=$DMOD_DMFC_DIR
export IDF_PATH=$IDF_PATH
export IDF_TOOLS_PATH=$TOOLS_DIR/.espressif
export PATH="\$PATH:$ARM_NONE_EABI_DIR_PATH/bin:$XTENSA_ESP_DIR_PATH/bin:/usr/local/bin"
[ -f "\$IDF_PATH/export.sh" ] && . "\$IDF_PATH/export.sh" >/dev/null 2>&1 || true
EOF
chmod 644 /etc/profile.d/dmod-dev.sh

# dmod/dmod-boot sources should be editable by whichever user logs in later
# (the login user doesn't exist yet at image-customization time).
chmod -R a+rwX "$SRC_DIR" "$TOOLS_DIR"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> dmod development environment ready:"
echo "      sources:    $SRC_DIR/dmod, $SRC_DIR/dmod-boot"
echo "      toolchains: $TOOLS_DIR (arm-none-eabi, xtensa-esp-elf, esp-idf)"
echo "      installed:  dmf-get, dmfc and friends under /usr/local"
