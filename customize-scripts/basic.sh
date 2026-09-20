#!/usr/bin/env bash
# Tier: basic - just enough to compile and install dmod on the Pi itself:
# the "mini" tier (SSH) plus build tools and a native dmod build/install.
# No embedded toolchains (arm-none-eabi/Xtensa/ESP-IDF), no Renode, no
# Node.js/Claude Code CLI - see the "full" tier for those.
#
# Mirrors modules/dmod/scripts/setup-linux-env.sh's package list (the
# project's own "native equivalent of Docker/Dockerfile.env" for dmod).
#
# Runs in one of two contexts:
#   - image-prep time, in the chroot via customize_image.sh (which
#     bind-mounts this repo read-only at /mnt/host-repo) - used when invoked
#     directly, e.g. `prepare_rpi_sd.py --customize-script .../basic.sh`.
#   - natively on the Pi's own first real boot, from a pre-staged copy at
#     $SRC_DIR/customize-scripts/basic.sh with dmod source already staged at
#     $SRC_DIR/dmod - this is what `prepare_rpi_sd.py --customize basic`
#     actually sets up (see mini.sh's --defer-tier), since a native build is
#     both faster and avoids qemu-emulation network flakiness.

set -euo pipefail

HOST_REPO=/mnt/host-repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$HOST_REPO/customize-scripts" ]]; then
    CUSTOMIZE_SCRIPTS_DIR="$HOST_REPO/customize-scripts"
else
    CUSTOMIZE_SCRIPTS_DIR="$SCRIPT_DIR"
fi
source "$CUSTOMIZE_SCRIPTS_DIR/common/paths.sh"

if [[ -d "$HOST_REPO" ]]; then
    echo "==> Running mini tier (enable SSH)"
    bash "$CUSTOMIZE_SCRIPTS_DIR/mini.sh"
fi

# DMOD_TOOLS_NAME picks the matching dmod/configs/arch/... toolchain config
# (see modules/dmod/configs/arch), and also which RPi cross-compiler package
# provides the "<triplet>-gcc" that config looks for via CROSS_COMPILE - even
# for a native build, since the config always searches for the prefixed name.
case "$(uname -m)" in
    aarch64|arm64)
        DMOD_TOOLS_NAME="arch/aarch64/cortex-a53"
        CROSS_PACKAGES="gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu"
        ;;
    armv7l|armv6l)
        DMOD_TOOLS_NAME="arch/armv7/cortex-a53"
        CROSS_PACKAGES="gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf"
        ;;
    x86_64)
        DMOD_TOOLS_NAME="arch/x86_64"
        CROSS_PACKAGES=""
        ;;
    *)
        echo "No dmod arch config known for $(uname -m)" >&2
        exit 1
        ;;
esac
echo "==> Building dmod with DMOD_TOOLS_NAME=$DMOD_TOOLS_NAME"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing packages needed to build dmod"
apt-get update
apt-get install -y --no-install-recommends \
    wget curl ca-certificates \
    gcc g++ make git jq zip unzip \
    libcurl4-openssl-dev libusb-1.0-0-dev openocd gcovr \
    cmake ninja-build gdb-multiarch \
    python3 python3-pip python3-venv \
    $CROSS_PACKAGES

echo "==> Installing choco-scripts"
curl -fsSL https://raw.githubusercontent.com/JohnAmadis/choco-scripts/refs/heads/master/install-choco-scripts.sh | bash

if [[ -d "$HOST_REPO/modules/dmod" ]]; then
    echo "==> Copying dmod source to $SRC_DIR/dmod"
    # rm+mkdir first: the working .img is reused across runs, so a stale
    # directory from a previous attempt may already exist here. `cp -a`
    # doesn't overwrite an existing directory, it nests into it, silently
    # building against leftover stale source instead of the current checkout.
    rm -rf "$SRC_DIR/dmod"
    mkdir -p "$SRC_DIR/dmod"
    cp -a "$HOST_REPO/modules/dmod/." "$SRC_DIR/dmod/"
    rm -rf "$SRC_DIR/dmod/build"  # in case the host checkout itself has one
elif [[ ! -d "$SRC_DIR/dmod" ]]; then
    echo "dmod source not found at $SRC_DIR/dmod and no /mnt/host-repo bind-mount available." >&2
    exit 1
else
    echo "==> Using pre-staged dmod source at $SRC_DIR/dmod"
fi

echo "==> Building & installing dmod"
mkdir -p "$DMOD_DMF_DIR" "$DMOD_DMFC_DIR"
(
    cd "$SRC_DIR/dmod"
    mkdir -p build
    cd build
    # DMOD_BUILD_TESTS=OFF: dmod/CMakeLists.txt turns on `--coverage` for
    # EVERY target (not just tests) whenever DMOD_BUILD_TESTS is on and
    # gcovr is installed (which basic.sh's own apt list does) - without this,
    # dmf-get/dmod_loader/etc. all end up gcov-instrumented, printing
    # "profiling: .../*.gcda: Cannot open" on every run once they're moved
    # out of the build tree (e.g. installed to /usr/local/bin). Also skips
    # building the whole gtest suite, which this tier doesn't need anyway.
    #
    # DMOD_BUILD_EXAMPLES stays OFF: examples/system/dmod_loader statically
    # links "system modules" (dmlist/dmosi/dmosi-posix/dmosi-proc) via
    # dmod_link_builtin(), which shells out to dmf-get at *configure* time
    # (scripts/CMakeLists.txt). This tier's job is just to compile and
    # install dmod itself (dmf-get, dmfc, the core library under
    # /usr/local), not the example binaries - see full.sh/README if you
    # want dmod_loader too.
    cmake .. -DDMOD_DMF_DIR="$DMOD_DMF_DIR" -DDMOD_DMFC_DIR="$DMOD_DMFC_DIR" \
             -DDMOD_TOOLS_NAME="$DMOD_TOOLS_NAME" -DDMOD_BUILD_EXAMPLES=OFF \
             -DDMOD_BUILD_TESTS=OFF
    cmake --build . --parallel "$(nproc)"
    cmake --install . --prefix=/usr/local --component tools
)

echo "==> Writing /etc/profile.d/dmod-dev.sh"
cat > /etc/profile.d/dmod-dev.sh <<EOF
# Added by customize-scripts/basic.sh
export DMOD_DMF_DIR=$DMOD_DMF_DIR
export DMOD_DMFC_DIR=$DMOD_DMFC_DIR
export PATH="\$PATH:/usr/local/bin"
EOF
chmod 644 /etc/profile.d/dmod-dev.sh

# dmod source should be editable by whichever user logs in later (the login
# user doesn't exist yet at image-customization time).
chmod -R a+rwX "$SRC_DIR" "$TOOLS_DIR"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> dmod build environment ready:"
echo "      source:    $SRC_DIR/dmod"
echo "      installed: dmf-get, dmfc and friends under /usr/local"
