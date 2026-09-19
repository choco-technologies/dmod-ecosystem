# dmod-ecosystem
Main repository for working with the DMOD ecosystem

## prepare_rpi_sd.py

Downloads a Raspberry Pi OS image and writes it to an SD card (Linux).

### Environment setup

```bash
source setup_venv.sh
```

This creates (if needed) a `.venv` virtualenv in the repo root, installs the
dependencies from `requirements.txt`, and activates it in the current shell.

### Usage

```bash
# List connected SD cards / removable USB drives
python3 prepare_rpi_sd.py --list-devices

# Download the default image (Raspberry Pi OS Lite 64-bit) and flash it,
# auto-detecting the SD card (works when exactly one removable device
# is connected)
sudo python3 prepare_rpi_sd.py

# Pick a different OS variant and an explicit device
sudo python3 prepare_rpi_sd.py --os full64 --device /dev/sdb

# Use a custom image (.img, .img.xz or .img.zip)
sudo python3 prepare_rpi_sd.py --image-url https://example.com/custom.img.xz

# Only download the image, without flashing it
python3 prepare_rpi_sd.py --download-only
```

Downloaded images go into the `images/` directory (ignored by git).

Before writing, the script asks for confirmation (unless `-y/--yes` is
used) and refuses to write to a device that looks like the system disk.
