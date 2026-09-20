#!/usr/bin/env python3
"""Downloads a Raspberry Pi OS image and writes it to an SD card.

Usage examples:

    # Download the default image (Raspberry Pi OS Lite 64-bit) and flash it,
    # auto-detecting the SD card (only works if exactly one is connected).
    sudo python3 prepare_rpi_sd.py

    # List available removable block devices.
    python3 prepare_rpi_sd.py --list-devices

    # Pick a different OS variant and an explicit device.
    sudo python3 prepare_rpi_sd.py --os full64 --device /dev/sdb

    # Use a custom image URL (.img, .img.xz or .img.zip).
    sudo python3 prepare_rpi_sd.py --image-url https://example.com/custom.img.xz
"""

from __future__ import annotations

import argparse
import json
import lzma
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

try:
    import requests
    from tqdm import tqdm
except ImportError:
    sys.exit(
        "Missing required modules. Install them with:\n"
        "  pip install -r requirements.txt\n"
        "(or run `source setup_venv.sh` to set up and activate a venv)."
    )

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DOWNLOAD_DIR = SCRIPT_DIR / "images"

# Stable "latest" links provided by the Raspberry Pi Foundation - they
# always point at the newest image of a given variant.
OS_IMAGES = {
    "lite64": "https://downloads.raspberrypi.com/raspios_lite_arm64_latest",
    "full64": "https://downloads.raspberrypi.com/raspios_arm64_latest",
    "lite32": "https://downloads.raspberrypi.com/raspios_lite_armhf_latest",
    "full32": "https://downloads.raspberrypi.com/raspios_armhf_latest",
}
DEFAULT_OS = "lite64"

# The three built-in customize tiers (see customize-scripts/README or the
# scripts themselves): mini < basic < full, each building on the previous.
CUSTOMIZE_TIERS = {
    "mini": SCRIPT_DIR / "customize-scripts" / "mini.sh",
    "basic": SCRIPT_DIR / "customize-scripts" / "basic.sh",
    "full": SCRIPT_DIR / "customize-scripts" / "full.sh",
}

# Auto tier selection thresholds: pick the richest tier that comfortably
# fits the target SD card. "basic" needs room for a dmod build; "full" adds
# several GB of embedded toolchains (ESP-IDF alone is a few GB) and Renode.
GIB = 1024**3
AUTO_TIER_MIN_SIZE = {
    "full": 64 * GIB,
    "basic": 8 * GIB,
}

# Raspberry Pi OS images ship with their root filesystem sized tight to their
# content (normally expanded to fill the SD card by a first-boot service) -
# there's rarely more than a few hundred MB free to install anything into.
# The "basic"/"full" tiers now do their actual (multi-GB) work natively on
# the Pi's own first real boot rather than in the working image (see
# mini.sh's --defer-tier), so all that's ever staged into the working image
# here is mini.sh's own lightweight work (a few small files, plus - for a
# deferred tier - a copy of the dmod/dmod-boot source, a few MB). This flat
# safety margin comfortably covers that regardless of tier.
DEFAULT_GROW_MB = 512

CHUNK_SIZE = 4 * 1024 * 1024  # 4 MiB


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kwargs)


# --------------------------------------------------------------------------
# Block device detection (SD cards)
# --------------------------------------------------------------------------

def list_removable_devices() -> list[dict]:
    """Returns the list of removable block devices (SD cards / USB) on Linux."""
    result = subprocess.run(
        ["lsblk", "-J", "-b", "-o", "NAME,SIZE,TYPE,RM,TRAN,MODEL,MOUNTPOINT"],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(result.stdout)

    devices = []
    for entry in data.get("blockdevices", []):
        if entry.get("type") != "disk":
            continue
        # Built-in SD card readers report their transport as "mmc", USB
        # devices as "usb". Internal card readers often report RM=0 even
        # though the card itself is removable, so for "mmc" we don't
        # require the RM flag - the transport alone is enough.
        if entry.get("tran") not in ("usb", "mmc"):
            continue
        devices.append(
            {
                "path": f"/dev/{entry['name']}",
                "size": int(entry.get("size") or 0),
                "model": (entry.get("model") or "").strip(),
                "tran": entry.get("tran"),
                "children": entry.get("children", []),
            }
        )
    return devices


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PiB"


def print_devices(devices: list[dict]) -> None:
    if not devices:
        print("No removable block devices found.")
        return
    print("Detected removable devices:")
    for dev in devices:
        model = dev["model"] or "unknown model"
        print(f"  {dev['path']}  -  {human_size(dev['size'])}  -  {model}  ({dev['tran']})")


def is_system_disk(device_path: str) -> bool:
    """Safety check: does this device contain the mounted / or /boot?"""
    result = subprocess.run(
        ["lsblk", "-J", "-o", "NAME,MOUNTPOINT"],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(result.stdout)
    target_name = Path(device_path).name

    def walk(entries, matched_root):
        for entry in entries:
            mp = entry.get("mountpoint")
            hit = matched_root or entry.get("name") == target_name
            if hit and mp in ("/", "/boot", "/boot/firmware"):
                return True
            if walk(entry.get("children", []), hit):
                return True
        return False

    return walk(data.get("blockdevices", []), False)


def pick_device(explicit: str | None) -> str:
    if explicit:
        device = explicit
        if not Path(device).exists():
            sys.exit(f"Device {device} does not exist.")
        return device

    devices = list_removable_devices()
    if not devices:
        sys.exit(
            "No SD card / USB drive detected. Connect one, or specify the "
            "device explicitly with --device /dev/sdX."
        )
    if len(devices) > 1:
        print_devices(devices)
        sys.exit(
            "\nMore than one removable device detected - specify which one "
            "with --device /dev/sdX to avoid picking the wrong one."
        )
    return devices[0]["path"]


def device_size_bytes(device_path: str) -> int:
    result = subprocess.run(
        ["lsblk", "-b", "-d", "-n", "-o", "SIZE", device_path],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(result.stdout.strip())


def auto_customize_tier(size_bytes: int) -> str:
    """Picks the richest customize tier that comfortably fits a card this size."""
    if size_bytes >= AUTO_TIER_MIN_SIZE["full"]:
        return "full"
    if size_bytes >= AUTO_TIER_MIN_SIZE["basic"]:
        return "basic"
    return "mini"


# --------------------------------------------------------------------------
# Image download
# --------------------------------------------------------------------------

def resolve_image_url(args: argparse.Namespace) -> str:
    if args.image_url:
        return args.image_url
    return OS_IMAGES[args.os]


def guess_filename(url: str, response: requests.Response) -> str:
    cd = response.headers.get("content-disposition", "")
    if "filename=" in cd:
        return cd.split("filename=", 1)[1].strip('"; ')
    name = Path(urlsplit(response.url).path).name
    return name or "raspios.img"


def download_image(url: str, download_dir: Path) -> Path:
    download_dir.mkdir(parents=True, exist_ok=True)

    with requests.get(url, stream=True, allow_redirects=True) as response:
        response.raise_for_status()
        filename = guess_filename(url, response)
        dest = download_dir / filename
        total = int(response.headers.get("content-length", 0))

        if dest.exists() and total and dest.stat().st_size == total:
            print(f"Image already downloaded: {dest} (skipping download).")
            return dest

        print(f"Downloading {response.url}\n  -> {dest}")
        tmp_dest = dest.with_suffix(dest.suffix + ".part")
        with open(tmp_dest, "wb") as fh, tqdm(
            total=total or None, unit="B", unit_scale=True, unit_divisor=1024
        ) as bar:
            for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
                if not chunk:
                    continue
                fh.write(chunk)
                bar.update(len(chunk))
        tmp_dest.rename(dest)

    return dest


# --------------------------------------------------------------------------
# Customization (mount the image and run a hook script inside a chroot)
# --------------------------------------------------------------------------

def raw_image_path_for(image_path: Path) -> Path:
    """Returns the path of the decompressed .img sibling of a .xz/.zip image."""
    suffix = image_path.suffix.lower()
    if suffix == ".xz":
        return image_path.with_suffix("")
    if suffix == ".zip":
        stem = image_path.stem
        return image_path.parent / (stem if stem.lower().endswith(".img") else f"{stem}.img")
    return image_path


def materialize_raw_image(image_path: Path) -> Path:
    """Fully decompresses image_path to a raw .img file, so it can be loop-mounted.

    Reuses an already-extracted file if present, so customizing/flashing again
    doesn't re-extract from scratch."""
    raw_path = raw_image_path_for(image_path)
    if raw_path == image_path:
        return image_path
    if raw_path.exists():
        print(f"Using already-extracted image: {raw_path}")
        return raw_path

    print(f"Extracting {image_path.name} -> {raw_path.name} ...")
    with open_image_stream(image_path) as src, open(raw_path, "wb") as dst, tqdm(
        unit="B", unit_scale=True, unit_divisor=1024, desc="Extracting"
    ) as bar:
        while True:
            chunk = src.read(CHUNK_SIZE)
            if not chunk:
                break
            dst.write(chunk)
            bar.update(len(chunk))
    return raw_path


def run_customize_script(
    image_path: Path, hook_script: Path, grow_mb: int = 0, hook_args: list[str] | None = None
) -> None:
    if not hook_script.exists():
        sys.exit(f"Customize script not found: {hook_script}")

    helper = SCRIPT_DIR / "customize_image.sh"
    if not helper.exists():
        sys.exit(f"Missing helper script: {helper}")

    print(f"Customizing {image_path.name} using {hook_script} (mount + chroot, needs root)...")
    cmd = ["bash", str(helper)]
    if grow_mb > 0:
        cmd += ["--grow-mb", str(grow_mb)]
    cmd += [str(image_path), str(hook_script)]
    if hook_args:
        cmd += ["--", *hook_args]
    subprocess.run(cmd, check=True)


# --------------------------------------------------------------------------
# Writing the image to the SD card
# --------------------------------------------------------------------------

def open_image_stream(image_path: Path):
    """Returns a file-like object with the .img contents (transparently
    decompressing .xz / .zip on the fly, without writing an extracted copy)."""
    suffix = image_path.suffix.lower()
    if suffix == ".xz":
        return lzma.open(image_path, "rb")
    if suffix == ".zip":
        zf = zipfile.ZipFile(image_path)
        img_names = [n for n in zf.namelist() if n.lower().endswith(".img")]
        if not img_names:
            sys.exit(f"No .img file found inside archive {image_path}.")
        return zf.open(img_names[0])
    return open(image_path, "rb")


def unmount_partitions(device_path: str) -> None:
    result = subprocess.run(
        ["lsblk", "-J", "-o", "NAME,MOUNTPOINT", device_path],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return
    data = json.loads(result.stdout)

    def walk(entries):
        for entry in entries:
            mp = entry.get("mountpoint")
            if mp:
                print(f"Unmounting {mp}...")
                subprocess.run(["umount", mp], check=False)
            walk(entry.get("children", []))

    walk(data.get("blockdevices", []))


def flash_image(image_path: Path, device_path: str) -> None:
    unmount_partitions(device_path)

    print(f"Writing {image_path.name} -> {device_path} ...")
    with open_image_stream(image_path) as src, open(device_path, "wb") as dst:
        with tqdm(unit="B", unit_scale=True, unit_divisor=1024, desc="Writing") as bar:
            while True:
                chunk = src.read(CHUNK_SIZE)
                if not chunk:
                    break
                dst.write(chunk)
                bar.update(len(chunk))
        dst.flush()
        os.fsync(dst.fileno())

    subprocess.run(["sync"], check=False)
    print("Write complete.")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--os",
        choices=sorted(OS_IMAGES),
        default=DEFAULT_OS,
        help=f"Raspberry Pi OS variant to download (default: {DEFAULT_OS}).",
    )
    parser.add_argument("--image-url", help="Custom image URL (.img / .img.xz / .img.zip), overrides --os.")
    parser.add_argument(
        "--download-dir",
        type=Path,
        default=DEFAULT_DOWNLOAD_DIR,
        help=f"Directory for downloaded images (default: {DEFAULT_DOWNLOAD_DIR}).",
    )
    parser.add_argument("--device", help="Target device, e.g. /dev/sdb. Auto-detected if not given.")
    parser.add_argument("--list-devices", action="store_true", help="List detected SD cards/USB drives and exit.")
    parser.add_argument(
        "--download-only",
        action="store_true",
        help="Only download the image, without flashing it.",
    )
    parser.add_argument(
        "--customize",
        choices=["auto", "none", *CUSTOMIZE_TIERS],
        default="auto",
        help=(
            "Which built-in customize tier to apply: 'mini' (SSH/wifi/user "
            "only, applied immediately), 'basic' (+ compiles and installs "
            "dmod) or 'full' (+ embedded toolchains, Renode, dmffs, Claude "
            "Code CLI - see customize-scripts/full.sh) - for basic/full, "
            "mini's setup still runs immediately, but the heavier build is "
            "staged to run natively the first time the Pi actually boots "
            "(much faster than building here under qemu-user-static, and "
            "avoids its network flakiness) - see customize-scripts/mini.sh "
            "--defer-tier. 'none' disables all of this. Default 'auto' picks "
            "the richest tier that comfortably fits the target SD card's "
            "size (mini/basic/full for roughly <8GB/<64GB/>=64GB) - ignored "
            "when --download-only is given unless --customize is set "
            "explicitly. Ignored if --customize-script is given."
        ),
    )
    parser.add_argument(
        "--customize-script",
        type=Path,
        help=(
            "Your own shell script to run inside the image before flashing it "
            "(via loop mount + chroot, see customize_image.sh), instead of one "
            "of the --customize tiers (and their wifi/user/defer handling). "
            "Requires root and forces the image to be fully decompressed to "
            "disk first. See customize-scripts/example.sh for a template."
        ),
    )
    parser.add_argument(
        "--wifi-ssid",
        help="Wi-Fi network to connect to on first boot (applied immediately by the mini tier).",
    )
    parser.add_argument("--wifi-password", help="Wi-Fi password. Omit for an open network.")
    parser.add_argument(
        "--wifi-country",
        help="2-letter Wi-Fi regulatory country code (e.g. PL, US, GB). Required if --wifi-ssid is given.",
    )
    parser.add_argument("--pi-username", help="Login user to create on the Pi (used together with --pi-password).")
    parser.add_argument("--pi-password", help="Password for --pi-username.")
    parser.add_argument("-y", "--yes", action="store_true", help="Don't ask for confirmation before writing.")
    return parser.parse_args(argv)


def validate_mini_args(args: argparse.Namespace) -> None:
    if args.wifi_ssid and not args.wifi_country:
        sys.exit("--wifi-country is required when --wifi-ssid is given.")
    if args.wifi_password and not args.wifi_ssid:
        sys.exit("--wifi-password requires --wifi-ssid.")
    if bool(args.pi_username) != bool(args.pi_password):
        sys.exit("--pi-username and --pi-password must be given together.")


def mini_hook_args(args: argparse.Namespace, defer_tier: str | None) -> list[str]:
    hook_args: list[str] = []
    if args.wifi_ssid:
        hook_args += ["--wifi-ssid", args.wifi_ssid, "--wifi-country", args.wifi_country]
        if args.wifi_password:
            hook_args += ["--wifi-password", args.wifi_password]
    if args.pi_username:
        hook_args += ["--username", args.pi_username, "--password", args.pi_password]
    if defer_tier:
        hook_args += ["--defer-tier", defer_tier]
    return hook_args


def confirm_flash(device_path: str, image_path: Path, auto_yes: bool) -> None:
    if is_system_disk(device_path):
        sys.exit(
            f"SAFETY: {device_path} looks like the system disk (contains / or /boot). "
            "Aborting."
        )

    print(f"\nImage:  {image_path}")
    print(f"Device: {device_path}")
    print("WARNING: all contents of this device will be permanently overwritten!")

    if auto_yes:
        return

    answer = input(f"Type '{device_path}' to confirm the write: ")
    if answer.strip() != device_path:
        sys.exit("Not confirmed - aborting.")


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)

    if args.list_devices:
        print_devices(list_removable_devices())
        return

    validate_mini_args(args)
    if args.customize_script and (args.wifi_ssid or args.pi_username):
        print(
            "Note: --wifi-* / --pi-* are only understood by the built-in "
            "mini/basic/full tiers, not by --customize-script - ignoring them."
        )

    url = resolve_image_url(args)
    image_path = download_image(url, args.download_dir)

    # Auto tier selection needs to know the target device's size, so it's
    # picked before customizing/flashing, not just before flashing. If the
    # user gave an explicit --device we can resolve it even with
    # --download-only (no auto-detect forced though, that would needlessly
    # require a card to be connected).
    device_path = None
    if args.device or not args.download_only:
        device_path = pick_device(args.device)

    customize_script = args.customize_script
    hook_args: list[str] = []
    if customize_script is None and args.customize != "none":
        if args.customize == "auto":
            if device_path is None:
                # --download-only with no device and no explicit tier: don't
                # guess a tier for a card we're not even looking at.
                tier = None
            else:
                size_bytes = device_size_bytes(device_path)
                tier = auto_customize_tier(size_bytes)
                print(f"Auto-selected customize tier '{tier}' for {device_path} ({human_size(size_bytes)})")
        else:
            tier = args.customize

        if tier is not None:
            # mini/basic/full all actually run via mini.sh: mini's own setup
            # (SSH/wifi/user) applies immediately, while basic/full are
            # staged to run natively the first time the Pi boots for real
            # instead (see mini.sh --defer-tier) - much faster than building
            # here under qemu-user-static, and avoids its network flakiness.
            customize_script = CUSTOMIZE_TIERS["mini"]
            defer_tier = tier if tier in ("basic", "full") else None
            hook_args = mini_hook_args(args, defer_tier)

    needs_root = customize_script is not None or not args.download_only
    if needs_root and os.geteuid() != 0:
        sys.exit(
            "This operation requires administrator privileges "
            "(mounting/writing the image) - run the script with sudo."
        )

    if customize_script is not None:
        image_path = materialize_raw_image(image_path)
        run_customize_script(image_path, customize_script, DEFAULT_GROW_MB, hook_args)

    if args.download_only:
        return

    confirm_flash(device_path, image_path, args.yes)
    flash_image(image_path, device_path)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Command {exc.cmd} failed ({exc.returncode}).")
    except KeyboardInterrupt:
        sys.exit("\nInterrupted by user.")
