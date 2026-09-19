#!/usr/bin/env bash
# Creates (if needed) and updates a virtualenv for prepare_rpi_sd.py.
#
# Usage:
#   source setup_venv.sh
#
# Must be *sourced* (not executed) so the venv activation affects your
# current shell.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"

if [[ ! -d "${VENV_DIR}" ]]; then
    echo "Creating virtualenv in ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

pip install --upgrade pip >/dev/null
pip install -r "${SCRIPT_DIR}/requirements.txt"

echo "Virtualenv ready and activated (${VENV_DIR})."
