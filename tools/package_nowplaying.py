#!/usr/bin/env python3
"""Add the experimental launch dylib to NightFox's proxy-enabled 9.44.2 IPA."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NAME = 'YTMU_NowPlayingLaunch_v0.1.dylib'
LOAD = ('@executable_path/Frameworks/' + NAME).encode() + b'\0'

def inject(data):
    b = bytearray(data)
    if len(b) < 32 or struct.unpack_from('<I', b)[0] != 0xFEEDFACF:
        raise ValueError('Expected a thin 64-bit Mach-O executable')
    count, length = struct.unpack_from('<II', b, 16)
    offset, first = 32, len(b)
    for _ in range(count):
        command, size = struct.unpack_from('<II', b, offset)
        if size < 8 or offset + size > 32 + length:
            raise ValueError('Invalid load command')
        if command == 0x19:
            sections = struct.unpack_from('<I', b, offset + 64)[0]
            for i in range(sections):
                section = offset + 72 + i * 80
                section_size = struct.unpack_from('<Q', b, section + 40)[0]
                file_offset = struct.unpack_from('<I', b, section + 48)[0]
                if file_offset and section_size:
                    first = min(first, file_offset)
        if command in (0xC, 0x18, 0x80000018):
            name_offset = struct.unpack_from('<I', b, offset + 8)[0]
            name = bytes(b[offset + name_offset:offset + size]).split(b'\0')[0]
            if NAME.encode() in name:
                raise ValueError('Launch patch already present')
        if command in (0x21, 0x2C) and struct.unpack_from('<I', b, offset + 16)[0]:
            raise ValueError('Encrypted executable; a decrypted input is required')
        offset += size
    if offset != 32 + length:
        raise ValueError('Load command size mismatch')
    size = (24 + len(LOAD) + 7) & ~7
    if offset + size > first or any(b[offset:offset + size]):
        raise ValueError('Insufficient zero header padding; refusing to shift data')
    cmd = struct.pack('<6I', 0xC, size, 24, 0, 0x10000, 0x10000) + LOAD
    b[offset:offset + size] = cmd.ljust(size, b'\0')
    struct.pack_into('<II', b, 16, count + 1, length + size)
    return bytes(b)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def package(ipa):
    output = ROOT / 'output/YTMUltimate_9.44.2_WireGuard_NowPlaying_v0.1.ipa'
    with tempfile.TemporaryDirectory(prefix='ytmu-launch-') as directory:
        work = Path(directory)
        with zipfile.ZipFile(ipa) as archive:
            for entry in archive.infolist():
                if entry.filename.startswith('/') or '..' in Path(entry.filename).parts:
                    raise ValueError('Unsafe archive member')
            archive.extractall(work)
        apps = list((work / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise ValueError('Expected one app')
        app = apps[0]
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if (info.get('CFBundleExecutable'), info.get('CFBundleShortVersionString'), info.get('CFBundleIdentifier')) != (
                'YouTubeMusic', '9.44.2', 'com.google.ios.youtubemusic'):
            raise ValueError('Use the inspected NightFox YouTube Music 9.44.2 input')
        original_libs = {p.relative_to(app).as_posix(): digest(p.read_bytes()) for p in app.rglob('*.dylib')}
        ytmu = app / 'Frameworks/YTMusicUltimate.dylib'
        if not ytmu.is_file() or b'YTMUWGSettingsController' not in ytmu.read_bytes():
            raise ValueError('Expected existing proxy-enabled YTMU')
        main = app / 'YouTubeMusic'
        main.write_bytes(inject(main.read_bytes()))
        main.chmod(0o755)
        shutil.copy2(ROOT / 'output' / NAME, app / 'Frameworks' / NAME)
        for signature in app.rglob('_CodeSignature'):
            if signature.is_dir():
                shutil.rmtree(signature)
        for profile in app.rglob('embedded.mobileprovision'):
            profile.unlink()
        subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', str(main)],
                       check=True, capture_output=True)
        for name, old in original_libs.items():
            if digest((app / name).read_bytes()) != old:
                raise ValueError('Existing injected library unexpectedly changed: ' + name)
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in sorted(work.rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(work))
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError('Output ZIP checksum failed')
    report = {'input_sha256': digest(ipa.read_bytes()), 'output_sha256': digest(output.read_bytes()),
              'bundle_identifier': info['CFBundleIdentifier'],
              'existing_libraries_preserved_byte_for_byte': original_libs,
              'added_library': NAME, 'status': 'Requires full device-certificate signing; device tap behavior unverified'}
    (ROOT / 'output/nowplaying-package.json').write_text(json.dumps(report, indent=2) + '\n')
    print(output)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    package(parser.parse_args().ipa)
