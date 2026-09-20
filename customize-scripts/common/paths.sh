# Shared path constants for the dmod customize-scripts tiers (mini < basic <
# full). Meant to be sourced, e.g.:
#   source "$HOST_REPO/customize-scripts/common/paths.sh"
# not run directly - it only makes sense inside a script that already
# defines HOST_REPO=/mnt/host-repo (see customize_image.sh).

SRC_DIR=/opt/dmod-src
TOOLS_DIR=/opt/dmod-tools
DMOD_DMF_DIR="$TOOLS_DIR/dmf"
DMOD_DMFC_DIR="$TOOLS_DIR/dmfc"
