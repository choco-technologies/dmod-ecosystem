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

DEFAULT_CUSTOMIZE_SCRIPT = SCRIPT_DIR / "customize-scripts" / "dmod-dev-environment.sh"

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


def run_customize_script(image_path: Path, hook_script: Path) -> None:
    if not hook_script.exists():
        sys.exit(f"Customize script not found: {hook_script}")

    helper = SCRIPT_DIR / "customize_image.sh"
    if not helper.exists():
        sys.exit(f"Missing helper script: {helper}")

    print(f"Customizing {image_path.name} using {hook_script} (mount + chroot, needs root)...")
    subprocess.run(["bash", str(helper), str(image_path), str(hook_script)], check=True)


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
        "--customize-script",
        type=Path,
        help=(
            "Shell script to run inside the image before flashing it (via loop "
            "mount + chroot, see customize_image.sh). Use it to preinstall "
            "packages, enable SSH, drop config files, etc. Requires root and "
            "forces the image to be fully decompressed to disk first. "
            f"Default (unless --download-only or --no-customize is given): "
            f"{DEFAULT_CUSTOMIZE_SCRIPT} (sets up a full DMOD dev environment). "
            "See customize-scripts/example.sh for a template of your own."
        ),
    )
    parser.add_argument(
        "--no-customize",
        action="store_true",
        help="Don't run any customize script, even the default one.",
    )
    parser.add_argument("-y", "--yes", action="store_true", help="Don't ask for confirmation before writing.")
    return parser.parse_args(argv)


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

    if args.no_customize:
        args.customize_script = None
    elif args.customize_script is None and not args.download_only:
        args.customize_script = DEFAULT_CUSTOMIZE_SCRIPT

    url = resolve_image_url(args)
    image_path = download_image(url, args.download_dir)

    needs_root = args.customize_script is not None or not args.download_only
    if needs_root and os.geteuid() != 0:
        sys.exit(
            "This operation requires administrator privileges "
            "(mounting/writing the image) - run the script with sudo."
        )

    if args.customize_script is not None:
        image_path = materialize_raw_image(image_path)
        run_customize_script(image_path, args.customize_script)

    if args.download_only:
        return

    device_path = pick_device(args.device)
    confirm_flash(device_path, image_path, args.yes)
    flash_image(image_path, device_path)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Command {exc.cmd} failed ({exc.returncode}).")
    except KeyboardInterrupt:
        sys.exit("\nInterrupted by user.")
