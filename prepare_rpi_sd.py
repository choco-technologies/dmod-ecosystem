#!/usr/bin/env python3
"""Pobiera obraz Raspberry Pi OS i zapisuje go na karcie SD.

Przykłady użycia:

    # Pobierz domyślny obraz (Raspberry Pi OS Lite 64-bit) i wgraj go,
    # automatycznie wykrywając kartę SD (jeśli podłączona jest tylko jedna).
    sudo python3 prepare_rpi_sd.py

    # Wypisz dostępne, wymienne urządzenia blokowe.
    python3 prepare_rpi_sd.py --list-devices

    # Wybierz inny obraz systemu i konkretne urządzenie.
    sudo python3 prepare_rpi_sd.py --os full64 --device /dev/sdb

    # Podaj własny URL do obrazu (.img, .img.xz lub .img.zip).
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
        "Brakuje wymaganych modułów. Zainstaluj je poleceniem:\n"
        "  pip install -r requirements.txt\n"
        "(albo uruchom `source setup_venv.sh`, żeby przygotować i aktywować venv)."
    )

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DOWNLOAD_DIR = SCRIPT_DIR / "images"

# Stabilne linki "latest" udostępniane przez Raspberry Pi Foundation -
# zawsze wskazują na najnowszy obraz danej odmiany.
OS_IMAGES = {
    "lite64": "https://downloads.raspberrypi.com/raspios_lite_arm64_latest",
    "full64": "https://downloads.raspberrypi.com/raspios_arm64_latest",
    "lite32": "https://downloads.raspberrypi.com/raspios_lite_armhf_latest",
    "full32": "https://downloads.raspberrypi.com/raspios_armhf_latest",
}
DEFAULT_OS = "lite64"

CHUNK_SIZE = 4 * 1024 * 1024  # 4 MiB


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kwargs)


# --------------------------------------------------------------------------
# Wykrywanie urządzeń blokowych (kart SD)
# --------------------------------------------------------------------------

def list_removable_devices() -> list[dict]:
    """Zwraca listę wymiennych urządzeń blokowych (karty SD / USB) na Linuksie."""
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
        if entry.get("rm") not in (True, "1", 1):
            continue
        # Karty SD w czytnikach wbudowanych bywają zgłaszane przez sterownik
        # "mmc", a przez USB - "usb". Obie traktujemy jako nośniki wymienne.
        if entry.get("tran") not in ("usb", "mmc", None):
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
        print("Nie znaleziono żadnych wymiennych urządzeń blokowych.")
        return
    print("Wykryte wymienne urządzenia:")
    for dev in devices:
        model = dev["model"] or "nieznany model"
        print(f"  {dev['path']}  -  {human_size(dev['size'])}  -  {model}  ({dev['tran']})")


def is_system_disk(device_path: str) -> bool:
    """Zabezpieczenie: sprawdza, czy urządzenie zawiera zamontowany / lub /boot."""
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
            sys.exit(f"Urządzenie {device} nie istnieje.")
        return device

    devices = list_removable_devices()
    if not devices:
        sys.exit(
            "Nie wykryto żadnej karty SD/USB. Podłącz kartę albo wskaż "
            "urządzenie ręcznie przez --device /dev/sdX."
        )
    if len(devices) > 1:
        print_devices(devices)
        sys.exit(
            "\nWykryto więcej niż jedno urządzenie wymienne - wskaż konkretne "
            "przez --device /dev/sdX, żeby uniknąć pomyłki."
        )
    return devices[0]["path"]


# --------------------------------------------------------------------------
# Pobieranie obrazu
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
            print(f"Obraz już pobrany: {dest} (pomijam pobieranie).")
            return dest

        print(f"Pobieranie {response.url}\n  -> {dest}")
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
# Zapis obrazu na kartę SD
# --------------------------------------------------------------------------

def open_image_stream(image_path: Path):
    """Zwraca obiekt plikopodobny z zawartością obrazu .img (transparentnie
    dekompresując .xz / .zip w locie, bez zapisywania rozpakowanej kopii)."""
    suffix = image_path.suffix.lower()
    if suffix == ".xz":
        return lzma.open(image_path, "rb")
    if suffix == ".zip":
        zf = zipfile.ZipFile(image_path)
        img_names = [n for n in zf.namelist() if n.lower().endswith(".img")]
        if not img_names:
            sys.exit(f"Nie znaleziono pliku .img w archiwum {image_path}.")
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
                print(f"Odmontowuję {mp}...")
                subprocess.run(["umount", mp], check=False)
            walk(entry.get("children", []))

    walk(data.get("blockdevices", []))


def flash_image(image_path: Path, device_path: str) -> None:
    unmount_partitions(device_path)

    print(f"Zapisywanie {image_path.name} -> {device_path} ...")
    with open_image_stream(image_path) as src, open(device_path, "wb") as dst:
        with tqdm(unit="B", unit_scale=True, unit_divisor=1024, desc="Zapisywanie") as bar:
            while True:
                chunk = src.read(CHUNK_SIZE)
                if not chunk:
                    break
                dst.write(chunk)
                bar.update(len(chunk))
        dst.flush()
        os.fsync(dst.fileno())

    subprocess.run(["sync"], check=False)
    print("Zapis zakończony.")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--os",
        choices=sorted(OS_IMAGES),
        default=DEFAULT_OS,
        help=f"Wariant Raspberry Pi OS do pobrania (domyślnie: {DEFAULT_OS}).",
    )
    parser.add_argument("--image-url", help="Własny URL obrazu (.img / .img.xz / .img.zip), nadpisuje --os.")
    parser.add_argument(
        "--download-dir",
        type=Path,
        default=DEFAULT_DOWNLOAD_DIR,
        help=f"Katalog na pobrane obrazy (domyślnie: {DEFAULT_DOWNLOAD_DIR}).",
    )
    parser.add_argument("--device", help="Urządzenie docelowe, np. /dev/sdb. Bez podania - autodetekcja.")
    parser.add_argument("--list-devices", action="store_true", help="Wypisz wykryte karty SD/USB i zakończ.")
    parser.add_argument(
        "--download-only",
        action="store_true",
        help="Tylko pobierz obraz, bez zapisywania na kartę.",
    )
    parser.add_argument("-y", "--yes", action="store_true", help="Nie pytaj o potwierdzenie przed zapisem.")
    return parser.parse_args(argv)


def confirm_flash(device_path: str, image_path: Path, auto_yes: bool) -> None:
    if is_system_disk(device_path):
        sys.exit(
            f"BEZPIECZEŃSTWO: {device_path} wygląda na dysk systemowy (zawiera / lub /boot). "
            "Przerywam."
        )

    print(f"\nObraz:     {image_path}")
    print(f"Urządzenie: {device_path}")
    print("UWAGA: cała zawartość urządzenia zostanie bezpowrotnie nadpisana!")

    if auto_yes:
        return

    answer = input(f"Wpisz '{device_path}', żeby potwierdzić zapis: ")
    if answer.strip() != device_path:
        sys.exit("Nie potwierdzono - przerywam.")


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)

    if args.list_devices:
        print_devices(list_removable_devices())
        return

    url = resolve_image_url(args)
    image_path = download_image(url, args.download_dir)

    if args.download_only:
        return

    if os.geteuid() != 0:
        sys.exit("Zapis na kartę SD wymaga uprawnień administratora - uruchom skrypt przez sudo.")

    device_path = pick_device(args.device)
    confirm_flash(device_path, image_path, args.yes)
    flash_image(image_path, device_path)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Polecenie {exc.cmd} zakończyło się błędem ({exc.returncode}).")
    except KeyboardInterrupt:
        sys.exit("\nPrzerwano przez użytkownika.")
