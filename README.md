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

# Customize the image (install packages, enable SSH, ...) before flashing
sudo python3 prepare_rpi_sd.py --customize-script ./customize-scripts/example.sh
```

### Customizing the image before flashing (`--customize-script`)

`--customize-script` lets you run a shell script *inside* the image's root
filesystem before it's written to the SD card - useful for preinstalling
packages, enabling SSH, dropping config files, adding a user, etc.

Under the hood, [customize_image.sh](customize_image.sh) does what people used
to do by hand: attach the `.img` file as a loop device (`losetup -P`), mount
its boot and root partitions, bind-mount `/dev`, `/proc`, `/sys`, and
`chroot` into it to run your script as root. It cleans up (unmount, detach
the loop device) automatically, even on failure.

The hook scripts themselves live in [customize-scripts/](customize-scripts/)
- add a new file there for each customization you want to keep around (e.g.
`customize-scripts/homelab.sh`, `customize-scripts/k3s-node.sh`).

Notes:
- Requires root (`sudo`), and forces the image to be fully decompressed to a
  local `.img` file first (loop-mounting a compressed `.img.xz` isn't
  possible) - see `images/`.
- If you're customizing an ARM image on an x86_64 host, you'll need
  `qemu-user-static` installed (`sudo apt install qemu-user-static
  binfmt-support`) so the chroot can execute the image's binaries.
- See [customize-scripts/example.sh](customize-scripts/example.sh) for a
  template (enabling SSH, setting the hostname, installing packages via
  `apt-get`) - copy it and adapt it to your needs.
- You can also run it standalone, without going through `prepare_rpi_sd.py`:
  `sudo ./customize_image.sh path/to/image.img customize-scripts/your-script.sh`.
- `customize_image.sh` also bind-mounts this repo read-only at
  `/mnt/host-repo` inside the chroot, so a hook script can use local sources
  (e.g. `modules/dmod`) without needing git credentials inside the chroot.

#### `customize-scripts/dmod-dev-environment.sh`

Turns the SD card into a full DMOD development environment - equivalent to
`chocotechnologies/dmod:1.0.4` plus the Renode/dmffs tooling from
dmod-boot's dev image and the Claude Code CLI - so you can build and debug
`dmod` and its modules directly on the Pi:

```bash
sudo python3 prepare_rpi_sd.py --customize-script ./customize-scripts/dmod-dev-environment.sh
```

It installs (mirroring `modules/dmod/Docker/Dockerfile.env`,
`modules/dmod/Docker/Dockerfile`, `modules/dmboot/docker/Dockerfile.env` and
`modules/dmod/Docker/Dockerfile.claude`):
- base build tools (gcc, cmake, ninja, git, python3, openocd, ...)
- the `arm-none-eabi` and Xtensa (ESP32) toolchains, plus ESP-IDF
- Renode (x86_64 host only - no arm64 package exists; real hardware debugging
  via OpenOCD works on any host)
- Node.js + the Claude Code CLI
- `dmod` itself, built and installed from this repo's `modules/dmod` checkout
  (via the `/mnt/host-repo` bind-mount), giving you `dmf-get`, `dmfc`, etc.

It copies editable working copies of `modules/dmod` and `modules/dmboot` to
`/opt/dmod-src/` on the image, and toolchains to `/opt/dmod-tools/` (both
added to `PATH` for every login shell via `/etc/profile.d/dmod-dev.sh`).
Takes a while to run (several downloads + a full `dmod` build under qemu
emulation if cross-customizing from an x86_64 host) - the `apt-get`/`wget`
steps need internet access on the machine running `prepare_rpi_sd.py`.

### OS variants (`--os`)

| Value    | Image                        | Description                                                                 |
|----------|-------------------------------|-------------------------------------------------------------------------------|
| `lite64` | Raspberry Pi OS Lite, 64-bit  | No desktop environment, boots to a console. Default. Recommended for headless setups (servers, IoT). Requires a 64-bit capable Pi (Pi 3 or newer). |
| `full64` | Raspberry Pi OS, 64-bit       | Full desktop environment with bundled apps. Requires a 64-bit capable Pi (Pi 3 or newer). |
| `lite32` | Raspberry Pi OS Lite, 32-bit  | No desktop environment, boots to a console. For older/32-bit-only boards (Pi 1, Pi 2, Pi Zero non-W2). |
| `full32` | Raspberry Pi OS, 32-bit       | Full desktop environment. For older/32-bit-only boards (Pi 1, Pi 2, Pi Zero non-W2). |

Downloaded images go into the `images/` directory (ignored by git).

Before writing, the script asks for confirmation (unless `-y/--yes` is
used) and refuses to write to a device that looks like the system disk.
