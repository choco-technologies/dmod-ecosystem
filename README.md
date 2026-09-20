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

# Download the default image (Raspberry Pi OS Lite 64-bit), auto-pick a
# customize tier that fits the target card's size (see below), and flash it,
# auto-detecting the SD card (works when exactly one removable device is
# connected)
sudo python3 prepare_rpi_sd.py

# Headless: configure Wi-Fi + a login user too (mini always applies these
# immediately; here paired with the default auto tier)
sudo python3 prepare_rpi_sd.py \
    --wifi-ssid MyNetwork --wifi-password mywifipass --wifi-country PL \
    --pi-username pi --pi-password raspberry

# Force a specific tier instead of auto-detecting one from the card size
sudo python3 prepare_rpi_sd.py --customize full  --pi-username pi --pi-password raspberry
sudo python3 prepare_rpi_sd.py --customize basic --pi-username pi --pi-password raspberry
sudo python3 prepare_rpi_sd.py --customize mini  --pi-username pi --pi-password raspberry

# Skip customization entirely - just download and flash a plain image
sudo python3 prepare_rpi_sd.py --customize none

# Pick a different OS variant and an explicit device
sudo python3 prepare_rpi_sd.py --os full64 --device /dev/sdb --customize full

# Use a custom image (.img, .img.xz or .img.zip)
sudo python3 prepare_rpi_sd.py --image-url https://example.com/custom.img.xz

# Only download the image, without customizing or flashing it
python3 prepare_rpi_sd.py --download-only

# Use your own customize script instead of one of the built-in tiers
sudo python3 prepare_rpi_sd.py --customize-script ./customize-scripts/example.sh
```

### Customizing the image before flashing (`--customize`)

Before flashing, a shell script can be run *inside* the image's root
filesystem - useful for preinstalling packages, enabling SSH, dropping
config files, building and installing software, etc.

There are three built-in tiers, each building on the previous one:

| Tier    | Script                                                     | What it does |
|---------|--------------------------------------------------------------|--------------|
| `mini`  | [customize-scripts/mini.sh](customize-scripts/mini.sh)   | Enables SSH, and optionally configures Wi-Fi and/or a login user (see `--wifi-*`/`--pi-*` below). Fits any card, applies immediately. |
| `basic` | [customize-scripts/basic.sh](customize-scripts/basic.sh) | `mini` + compiles and installs `dmod` (native, no embedded toolchains). |
| `full`  | [customize-scripts/full.sh](customize-scripts/full.sh)   | `basic` + embedded toolchains (arm-none-eabi, Xtensa/ESP-IDF), Renode, dmffs, Node.js + Claude Code CLI - see details below. |

`--customize` picks the tier (`mini`/`basic`/`full`/`none`). The default,
`auto`, picks the richest tier that comfortably fits the target SD card:

- card size **< 8 GB** → `mini`
- **8-64 GB** → `basic` (e.g. a 16 GB card)
- **≥ 64 GB** → `full`

`auto` needs a target device to size, so with `--download-only` it's a no-op
(nothing is customized) unless `--customize` is set explicitly. Use
`--customize-script` instead to run your own script in place of a tier.

#### `mini` runs immediately; `basic`/`full` run on the Pi's first boot

Building `dmod` (let alone the full embedded toolchain) is heavy - lots of
downloads and a real compile. Doing that here, in a loop-mounted image, under
`qemu-user-static` emulation (needed whenever the image's architecture
doesn't match the machine running `prepare_rpi_sd.py`, e.g. flashing an
aarch64 image from an x86_64 desktop) is slow and prone to network flakiness
inside the emulated environment.

So only `mini`'s own work (SSH, Wi-Fi, user account) runs immediately, in the
chroot. For `basic`/`full`, `mini.sh` *also* stages the `dmod`/`dmod-boot`
source and the `customize-scripts/` themselves onto the image, and installs a
oneshot systemd service (`dmod-first-boot.service`) that runs `basic.sh` or
`full.sh` **natively, the first time the Pi actually boots** - after
`network-online.target`, so it has real internet access. This is both much
faster (real ARM CPU, no emulation) and more reliable (real network stack).

After first boot, check on it over SSH with:
```bash
journalctl -u dmod-first-boot -f
# or
tail -f /var/log/dmod-first-boot.log
```
It disables itself (and drops a `/var/lib/dmod-first-boot.done` marker) once
it's run, successfully or not - it won't re-run on later boots.

#### Wi-Fi and login user (`--wifi-*` / `--pi-*`)

Since `basic`/`full`'s real work now happens after the Pi boots for real (and
even for `mini`, you need a way to actually reach a headless Pi), you'll
generally want to configure network + a login account:

- `--wifi-ssid SSID --wifi-country CC [--wifi-password PASS]` - writes a
  NetworkManager connection profile directly (Raspberry Pi OS's network stack
  since Bookworm) and sets the Wi-Fi regulatory domain via `raspi-config
  nonint do_wifi_country` (needed for the radio to come up in most regions).
  Omit `--wifi-password` for an open network. `--wifi-country` is a 2-letter
  ISO code (e.g. `PL`, `US`, `GB`).
- `--pi-username USER --pi-password PASS` - creates the account with
  `useradd`/`chpasswd` (in the `sudo` group). Recent Raspberry Pi OS images
  ship no default user at all, so without this you may not be able to log in
  even with SSH enabled - `prepare_rpi_sd.py` prints a warning in that case.

Both are optional and independent of `--customize` - e.g. `--customize none
--wifi-ssid ...` doesn't apply (customize none skips mini entirely); to just
set up Wi-Fi/user without the dmod build, use `--customize mini` explicitly.

#### Mechanics

Under the hood, [customize_image.sh](customize_image.sh) does what people used
to do by hand: attach the `.img` file as a loop device (`losetup -P`), mount
its boot and root partitions, bind-mount `/dev`, `/proc`, `/sys`, and
`chroot` into it to run the script as root. It cleans up (unmount, detach the
loop device) automatically, even on failure. It also bind-mounts this repo
read-only at `/mnt/host-repo` inside the chroot, so a script can use local
sources (e.g. `modules/dmod`) or invoke sibling `customize-scripts/*.sh`
files without needing git credentials inside the chroot.

Notes:
- Requires root (`sudo`), and forces the image to be fully decompressed to a
  local `.img` file first (loop-mounting a compressed `.img.xz` isn't
  possible) - see `images/`.
- The working image is grown a little (`customize_image.sh --grow-mb 512`:
  resizes the partition with `parted` and the filesystem with `resize2fs`
  before mounting) since shipped Raspberry Pi OS images leave almost no free
  space until their first real boot expands the filesystem - `mini`'s own
  files plus a staged `dmod`/`dmod-boot` source copy easily fit in that.
  Requires `parted` and `e2fsprogs` (`resize2fs`, `e2fsck`) on the host
  running `prepare_rpi_sd.py`.
- If you're customizing an ARM image on an x86_64 host, you'll need
  `qemu-user-static` installed (`sudo apt install qemu-user-static
  binfmt-support`) so the chroot can execute the image's binaries (needed for
  `mini`'s own work - `useradd`, `raspi-config`, etc. - the deferred
  `basic`/`full` build itself runs later, natively, on the Pi).
- See [customize-scripts/example.sh](customize-scripts/example.sh) for a
  template of your own (not part of the mini/basic/full chain) - copy it and
  adapt it to your needs, then point `--customize-script` at your copy.
- You can also run any of these standalone, without going through
  `prepare_rpi_sd.py`, e.g.:
  `sudo ./customize_image.sh path/to/image.img customize-scripts/mini.sh -- --wifi-ssid ... --wifi-country PL --defer-tier basic`.

#### `customize-scripts/full.sh`

Turns the SD card into a full DMOD development environment - equivalent to
`chocotechnologies/dmod:1.0.4` plus the Renode/dmffs tooling from
dmod-boot's dev image and the Claude Code CLI - so you can build and debug
`dmod` and its modules directly on the Pi.

On top of what `basic.sh` already does (see its own package list, mirroring
`modules/dmod/scripts/setup-linux-env.sh`), it installs (mirroring
`modules/dmod/Docker/Dockerfile.env`, `modules/dmboot/docker/Dockerfile.env`,
`modules/dmboot/scripts/setup-linux-env.sh` and
`modules/dmod/Docker/Dockerfile.claude`):
- the `arm-none-eabi` and Xtensa (ESP32) toolchains, plus ESP-IDF (which also
  pulls in the Espressif OpenOCD fork needed for ESP32-S3 JTAG)
- both `aarch64-linux-gnu` and `arm-linux-gnueabihf` cross-compilers (whichever
  one matches the image is already installed by `basic.sh`)
- Renode (x86_64 host only - no arm64 package exists; real hardware debugging
  via OpenOCD works on any host)
- Node.js + the Claude Code CLI
- dmffs, via `dmf-get make_dmffs --type dmf` (best-effort: a network/registry
  hiccup here is logged as a warning rather than failing the whole build)
- an editable copy of `modules/dmod-boot` under `/opt/dmod-src/` (not built -
  it's firmware, built per-target once you're on the board)

`basic.sh` builds `dmod` itself, from the staged source at `/opt/dmod-src/dmod`
(originally copied from this repo's `modules/dmod` checkout by `mini.sh`),
with `-DDMOD_TOOLS_NAME` set to the matching `configs/arch/...` entry for the
Pi's own architecture (e.g. `arch/aarch64/cortex-a53` for a 64-bit Pi 3B),
giving you `dmf-get`, `dmfc`, etc. under `/usr/local`. Both scripts also work
if run directly in the image-prep chroot instead of at first boot (they fall
back to copying straight from the `/mnt/host-repo` bind-mount when it's
present); toolchains go to `/opt/dmod-tools/` (added to `PATH` for every
login shell via `/etc/profile.d/dmod-dev.sh`).

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
