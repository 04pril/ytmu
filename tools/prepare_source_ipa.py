#!/usr/bin/env python3
"""Remove earlier Cyan tweak injections before a new build from an already tweaked IPA."""
import argparse
import os
import tempfile
import zipfile
from pathlib import Path

import lief


INJECTED_DYLIBS = {
    "YTMusicUltimate.dylib",
    "ReturnYouTubeMusicDislikes.dylib",
    "YTMABConfig.dylib",
    "YouMusicPiP.dylib",
    "VolumeBoostYT.dylib",
    "YTMUWidgetGroupFix.dylib",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        parser.error("Source and destination must differ")
    with zipfile.ZipFile(args.source) as source:
        app_infos = [i for i in source.infolist() if i.filename.startswith("Payload/") and i.filename.count("/") == 2 and i.filename.endswith("/Info.plist")]
        if len(app_infos) != 1:
            parser.error("Expected exactly one app in the IPA")
        import plistlib
        app_info = plistlib.loads(source.read(app_infos[0]))
        app_root = app_infos[0].filename.removesuffix("Info.plist")
        executable = app_root + app_info["CFBundleExecutable"]
        if executable not in source.namelist():
            parser.error(f"Missing app executable: {executable}")
        with tempfile.TemporaryDirectory() as tmp:
            binary_path = Path(tmp) / "app"
            binary_path.write_bytes(source.read(executable))
            fat = lief.MachO.parse(str(binary_path))
            if fat is None or len(fat) == 0:
                parser.error("Cannot parse app Mach-O")
            removed = []
            for binary in fat:
                for library in list(binary.libraries):
                    name = os.path.basename(library.name)
                    if name in INJECTED_DYLIBS and library.command != lief.MachO.LoadCommand.TYPE.ID_DYLIB:
                        if not binary.remove(library):
                            parser.error(f"Cannot remove load command: {library.name}")
                        removed.append(name)
            if removed:
                fat.write(str(binary_path))
                rebuilt = lief.MachO.parse(str(binary_path))
                if rebuilt is None or any(os.path.basename(lib.name) in INJECTED_DYLIBS for binary in rebuilt for lib in binary.libraries):
                    parser.error("Injected load command remains after rewriting Mach-O")
            skipped = []
            args.destination.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(args.destination, "w") as output:
                for entry in source.infolist():
                    name = entry.filename
                    if name.startswith(app_root + "Frameworks/") and name.count("/") == app_root.count("/") + 1 and os.path.basename(name) in INJECTED_DYLIBS:
                        skipped.append(os.path.basename(name))
                        continue
                    output.writestr(entry, binary_path.read_bytes() if name == executable and removed else source.read(entry))
            print(f"Removed load commands: {sorted(removed)}")
            print(f"Removed embedded dylibs: {sorted(skipped)}")


if __name__ == "__main__":
    main()
