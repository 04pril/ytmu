#!/usr/bin/env python3
"""Copy and patch the stock WidgetKit extension to load the app-group shim."""
import argparse
import plistlib
import shutil
from pathlib import Path

import lief


LOAD_PATH = "@executable_path/../../Frameworks/YTMUWidgetGroupFix.dylib"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    source = args.source
    destination = args.destination
    info = plistlib.loads((source / "Info.plist").read_bytes())
    if info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        parser.error(f"Not a WidgetKit extension: {source}")
    if destination.exists():
        parser.error(f"Destination already exists: {destination}")
    shutil.copytree(source, destination, symlinks=True)
    executable = destination / info["CFBundleExecutable"]
    fat = lief.MachO.parse(str(executable))
    if fat is None or len(fat) == 0:
        parser.error(f"Cannot parse Mach-O: {executable}")
    for binary in fat:
        if not any(lib.name == LOAD_PATH for lib in binary.libraries):
            binary.add(lief.MachO.DylibCommand.weak_lib(LOAD_PATH))
    fat.write(str(executable))
    check = lief.MachO.parse(str(executable))
    if check is None or not all(any(lib.name == LOAD_PATH for lib in binary.libraries) for binary in check):
        parser.error("Failed to add the widget shim load command")


if __name__ == "__main__":
    main()
