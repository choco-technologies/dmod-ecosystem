#!/usr/bin/env bash
# Turns the SD card image into a full DMOD development environment,
# equivalent to what you get in the chocotechnologies/dmod:1.0.4 Docker
# image plus the Renode/dmffs tooling from dmod-boot's dev image and the
# Claude Code CLI - so dmod and its modules can be built and debugged
# directly on the Raspberry Pi.
#
# It mirrors, in order:
#   - modules/dmod/Docker/Dockerfile.env   (base packages + toolchains)
#   - modules/dmod/Docker/Dockerfile       (build & install dmod itself)
#   - modules/dmboot/docker/Dockerfile.env (Renode + extra packages)
#   - modules/dmod/Docker/Dockerfile.claude (Node.js + Claude Code CLI)
#
# Run via prepare_rpi_sd.py --customize-script, or standalone:
#   sudo ./customize_image.sh <image.img> customize-scripts/dmod-dev-environment.sh
#
# customize_image.sh bind-mounts this repo read-only at /mnt/host-repo, so
# modules/dmod and modules/dmboot sources are available without needing git
# credentials inside the chroot.

set -euo pipefail

HOST_REPO=/mnt/host-repo
SRC_DIR=/opt/dmod-src
TOOLS_DIR=/opt/dmod-tools

if [[ ! -d "$HOST_REPO/modules/dmod" ]]; then
    echo "Expected $HOST_REPO/modules/dmod (repo bind-mount) - is this being run via customize_image.sh?" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64)          HOST_ARCH=x86_64 ;;
    aarch64|arm64)   HOST_ARCH=aarch64 ;;
    *)
        echo "Unsupported host architecture: $(uname -m)" >&2
        exit 1
        ;;
esac
echo "==> Target architecture inside the image: $HOST_ARCH"

# DMOD_TOOLS_NAME picks the matching dmod/configs/arch/... toolchain config
# (see modules/dmod/configs/arch) so dmod is built with the right compiler
# and CPU flags for this board, instead of the "arch/x86_64" default.
case "$(uname -m)" in
    x86_64)          DMOD_TOOLS_NAME="arch/x86_64" ;;
    aarch64|arm64)   DMOD_TOOLS_NAME="arch/aarch64/cortex-a53" ;;
    armv7l|armv6l)   DMOD_TOOLS_NAME="arch/armv7/cortex-a53" ;;
    *)
        echo "No dmod arch config known for $(uname -m)" >&2
        exit 1
        ;;
esac
echo "==> Building dmod with DMOD_TOOLS_NAME=$DMOD_TOOLS_NAME"

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# 1. Base packages (modules/dmod/Docker/Dockerfile.env +
#    modules/dmboot/docker/Dockerfile.env)
# --------------------------------------------------------------------------

echo "==> Installing base development packages"
apt-get update
apt-get install -y --no-install-recommends \
    wget curl ca-certificates gnupg \
    gcc g++ make git jq zip unzip xz-utils \
    libcurl4-openssl-dev gcovr openocd libusb-1.0-0 \
    cmake ninja-build \
    python3 python3-pip python3-venv \
    libncurses5 policykit-1 libgtk2.0-0 screen uml-utilities libc6-dev \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
    gdb-multiarch

# --------------------------------------------------------------------------
# 2. choco-scripts (modules/dmod/Docker/Dockerfile.env)
# --------------------------------------------------------------------------

echo "==> Installing choco-scripts"
curl -fsSL https://raw.githubusercontent.com/JohnAmadis/choco-scripts/refs/heads/master/install-choco-scripts.sh | bash

mkdir -p "$TOOLS_DIR"

# --------------------------------------------------------------------------
# 3. arm-none-eabi toolchain (modules/dmod/Docker/Dockerfile.env)
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
# 4. Xtensa (ESP32) toolchain + ESP-IDF (modules/dmod/Docker/Dockerfile.env)
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
# 5. Renode (modules/dmboot/docker/Dockerfile.env) - x86_64 only, Renode
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
# 6. cmake (modules/dmod/Docker/Dockerfile.env pins a specific version;
#    the apt package installed above is a reasonable fallback if this fails)
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
# 7. Build & install dmod (modules/dmod/Docker/Dockerfile), from the local
#    checkout bind-mounted at $HOST_REPO - keeps an editable copy under
#    $SRC_DIR/dmod for day-to-day development.
# --------------------------------------------------------------------------

echo "==> Copying dmod source to $SRC_DIR/dmod"
mkdir -p "$SRC_DIR"
cp -a "$HOST_REPO/modules/dmod" "$SRC_DIR/dmod"
rm -rf "$SRC_DIR/dmod/build"

echo "==> Building & installing dmod"
export DMOD_DMF_DIR=/opt/dmod-tools/dmf
export DMOD_DMFC_DIR=/opt/dmod-tools/dmfc
mkdir -p "$DMOD_DMF_DIR" "$DMOD_DMFC_DIR"
(
    cd "$SRC_DIR/dmod"
    mkdir -p build
    cd build
    # Two-pass configure: see the comment in modules/dmod/Docker/Dockerfile -
    # dmf-get must exist on disk before re-configuring with examples on.
    cmake .. -DDMOD_DMF_DIR="$DMOD_DMF_DIR" -DDMOD_DMFC_DIR="$DMOD_DMFC_DIR" \
             -DDMOD_TOOLS_NAME="$DMOD_TOOLS_NAME" -DDMOD_BUILD_EXAMPLES=OFF
    cmake --build . --target dmf-get
    cmake .. -DDMOD_BUILD_EXAMPLES=ON
    cmake --build .
    cmake --install . --prefix=/usr/local --component tools
)

# --------------------------------------------------------------------------
# 8. dmod-boot source, as an editable starting point (not built here - it's
#    firmware, built per-target once you're on the board).
# --------------------------------------------------------------------------

if [[ -d "$HOST_REPO/modules/dmboot" ]]; then
    echo "==> Copying dmod-boot source to $SRC_DIR/dmod-boot"
    cp -a "$HOST_REPO/modules/dmboot" "$SRC_DIR/dmod-boot"
    rm -rf "$SRC_DIR/dmod-boot/build"
fi

# --------------------------------------------------------------------------
# 9. Node.js + Claude Code CLI (modules/dmod/Docker/Dockerfile.claude)
# --------------------------------------------------------------------------

echo "==> Installing Node.js and the Claude Code CLI"
NODE_MAJOR=20
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs ripgrep
npm install -g @anthropic-ai/claude-code

# --------------------------------------------------------------------------
# 10. Wire up PATH / env vars for every login shell
# --------------------------------------------------------------------------

echo "==> Writing /etc/profile.d/dmod-dev.sh"
cat > /etc/profile.d/dmod-dev.sh <<EOF
# Added by customize-scripts/dmod-dev-environment.sh
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
