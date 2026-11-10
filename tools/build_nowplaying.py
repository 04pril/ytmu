#!/usr/bin/env python3
"""Build only the additive launch repair; keep the existing YTMU/WireGuard dylib."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def build():
    output = ROOT / 'output'
    output.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    dylib = output / 'YTMU_NowPlayingLaunch_v0.1.dylib'
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.0',
                    '-isysroot', sdk, '-fobjc-arc', '-fblocks', '-O2', '-Wall', '-Wextra',
                    '-Wno-unused-parameter', '-Wno-deprecated-declarations', '-dynamiclib',
                    str(ROOT / 'Source/NowPlaying/YTMUNowPlayingFix.m'),
                    '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'MediaPlayer',
                    '-Wl,-install_name,@rpath/YTMU_NowPlayingLaunch_v0.1.dylib',
                    '-o', str(dylib)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(dylib)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(dylib)], check=True)
    report = {'base_repository': 'kes158/YTMusicUltimate',
              'base_commit': '8ca2d6f8684d87ddd90c32ee96797588b57e0c41',
              'dylib_sha256': hashlib.sha256(dylib.read_bytes()).hexdigest(),
              'status': 'Experimental: compiled and host harness tested; lock-screen and Dynamic Island require device verification.',
              'proxy': 'Existing upstream WireGuard retained; this additive dylib contains no second proxy engine.'}
    (output / 'nowplaying-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(dylib)

if __name__ == '__main__':
    build()
