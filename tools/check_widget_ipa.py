#!/usr/bin/env python3
"""Reject an IPA with duplicate tweak loads or a disconnected widget shim."""
import argparse
import collections
import plistlib
import struct
import zipfile


DYLIB_COMMANDS = {0xC, 0x18, 0x1F, 0x20, 0x23}
SHIM_NAME = "YTMUWidgetGroupFix.dylib"
WIDGET_LOAD = "@executable_path/../../Frameworks/" + SHIM_NAME


def dylib_loads(data):
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected an arm64 Mach-O executable")
    command_count, command_bytes = struct.unpack_from("<II", data, 16)
    end = 32 + command_bytes
    position = 32
    loads = []
    for _ in range(command_count):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > end:
            raise ValueError("Invalid Mach-O load command")
        if command & 0x7FFFFFFF in DYLIB_COMMANDS:
            name_offset = struct.unpack_from("<I", data, position + 8)[0]
            if name_offset >= size:
                raise ValueError("Invalid dylib name offset")
            name = data[position + name_offset:position + size].split(b"\0", 1)[0].decode("utf-8")
            loads.append(name)
        position += size
    if position != end:
        raise ValueError("Mach-O load commands have inconsistent sizes")
    return loads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    args = parser.parse_args()
    with zipfile.ZipFile(args.ipa) as ipa:
        infos = [n for n in ipa.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith("/Info.plist")]
        if len(infos) != 1:
            parser.error("Expected one app bundle")
        app = infos[0].removesuffix("Info.plist")
        executable = plistlib.loads(ipa.read(infos[0]))["CFBundleExecutable"]
        main_loads = dylib_loads(ipa.read(app + executable))
        duplicates = [name for name, count in collections.Counter(main_loads).items() if count > 1]
        if duplicates:
            parser.error(f"Duplicate linked dylibs: {duplicates}")
        shim = app + "Frameworks/" + SHIM_NAME
        widget = app + "PlugIns/YouTubeMusicWidgetKitExtension.appex/YouTubeMusicWidgetKitExtension"
        if shim not in ipa.namelist() or WIDGET_LOAD not in dylib_loads(ipa.read(widget)):
            parser.error("Widget group shim is absent or not loaded by the widget")
        print("No duplicate dylibs; widget group shim is present and loaded")


if __name__ == "__main__":
    main()
