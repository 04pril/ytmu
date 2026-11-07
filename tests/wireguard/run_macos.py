#!/usr/bin/env python3
"""Run the app-local WireGuard core against Apple's real NSURLSession on macOS.

Builds the Go engine for macOS, the test WireGuard peer and the Objective-C
harness, then checks (with freshly generated test keys only):

* NSURLSession -> authenticated SOCKS5 (nw_proxy_config, failover disabled)
  -> Go engine -> WireGuard handshake -> peer: HTTPS, HTTP 206, tunnel DNS
* no direct fallback: a host reachable directly but not through the tunnel
  is never contacted, also when the WireGuard peer is dead
* Google transport patch logic against mocks of the 9.42.2 selectors
* diagnostics contain no private key, signed URL, host or address

Usage: python3 tests/wireguard/run_macos.py [--out results.json]
"""
import argparse
import http.server
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
WG = ROOT / "WireGuard"


def sh(cmd, **kw):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=True, **kw)


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))  # no packet is sent for UDP connect
        ip = s.getsockname()[0]
        return None if ip.startswith("127.") else ip
    except OSError:
        return None
    finally:
        s.close()


class DirectHandler(http.server.BaseHTTPRequestHandler):
    hits = 0

    def do_GET(self):
        DirectHandler.hits += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"direct")

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix="ytmuwg-") as tmp:
        tmp = pathlib.Path(tmp)
        env = dict(os.environ, CGO_ENABLED="1")
        sh(["go", "build", "-o", str(tmp / "testpeer"), "./cmd/ytmuwg-testpeer"], cwd=WG, env=env)
        sh(["go", "build", "-buildmode=c-archive", "-o", str(tmp / "libytmuwg-macos.a"), "."], cwd=WG, env=env)
        harness = tmp / "harness"
        sh(["xcrun", "clang", "-fobjc-arc", "-fmodules", "-DYTMUWG_TESTING", "-mmacosx-version-min=14.0", "-Wall",
            str(ROOT / "Source/WireGuard/YTMUWGCore.m"), str(ROOT / "Source/WireGuard/YTMUWGTransport.m"),
            str(ROOT / "tests/wireguard/harness.m"), str(tmp / "libytmuwg-macos.a"),
            "-framework", "Foundation", "-framework", "Network", "-framework", "Security",
            "-framework", "CoreFoundation", "-lresolv", "-o", str(harness)])

        peer_dir = tmp / "peer"
        peer_dir.mkdir()
        peer = subprocess.Popen([str(tmp / "testpeer"), "-out", str(peer_dir)])
        try:
            for _ in range(100):
                if (peer_dir / "ready.json").exists():
                    break
                time.sleep(0.1)
            ready = json.loads((peer_dir / "ready.json").read_text())
            stats_url = f"http://127.0.0.1:{ready['statsPort']}/"

            def stats():
                with urllib.request.urlopen(stats_url, timeout=5) as r:
                    return json.load(r)

            direct = http.server.ThreadingHTTPServer(("0.0.0.0", 0), DirectHandler)
            threading.Thread(target=direct.serve_forever, daemon=True).start()
            ip = lan_ip()
            direct_url = f"http://{ip}:{direct.server_port}/direct" if ip else ""
            if not ip:
                print("NOTE no non-loopback IPv4 address; direct-fallback probe skipped", flush=True)

            base = dict(os.environ, YTMUWG_TEST_ENABLED="1", YTMUWG_TEST_PROFILE=str(peer_dir / "client.conf"),
                        YTMUWG_TEST_CERT=str(peer_dir / "fixture.der"), YTMUWG_TEST_DIRECT_URL=direct_url,
                        YTMUWG_TEST_APP_VERSION="9.42.2", YTMUWG_EXPECT_ACTIVE="1", YTMUWG_EXPECT_STACK="0")

            def run(name, mode, **extra):
                proc = subprocess.run([str(harness), mode], env=dict(base, **extra), capture_output=True, text=True, timeout=180)
                sys.stdout.write(proc.stdout)
                sys.stderr.write(proc.stderr)
                if proc.returncode != 0:
                    raise SystemExit(f"FAILED: {name} (exit {proc.returncode})")
                results.append(name)
                return proc.stdout

            run("unit: protobuf enum names select URLSession value", "unit", YTMUWG_TEST_ENUM_NAMES="1")
            run("unit: no enum names, verified 9.42.2 -> 0", "unit")
            run("unit: no enum names, unverified version -> observe only", "unit",
                YTMUWG_TEST_APP_VERSION="9.99.0", YTMUWG_EXPECT_STACK="3")
            run("unit: unverified version with user override -> 0", "unit",
                YTMUWG_TEST_APP_VERSION="9.99.0", YTMUWG_TEST_FORCE_STACK="1")
            run("unit: disabled -> no hooks", "unit", YTMUWG_TEST_ENABLED="0", YTMUWG_EXPECT_ACTIVE="0")

            before = stats()
            out = run("net: NSURLSession through WireGuard (HTTPS, 206, tunnel DNS, shared session, NSData)", "net")
            after = stats()
            assert after["dns"] > before["dns"], ("tunnel DNS not used", before, after)
            assert after["https"] > before["https"] and after["range"] > before["range"], (before, after)
            assert DirectHandler.hits == 0, "direct server was contacted"
            results.append(f"peer counters: dns +{after['dns'] - before['dns']}, https +{after['https'] - before['https']}, range +{after['range'] - before['range']}; direct hits 0")
            report = out[out.find("YTMU app-local WireGuard diagnostics"):]

            # Dead peer: profile points at a UDP port nobody serves.
            dead = (peer_dir / "client.conf").read_text()
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            probe.bind(("127.0.0.1", 0))
            dead_port = probe.getsockname()[1]
            probe.close()
            dead = "\n".join(f"Endpoint = 127.0.0.1:{dead_port}" if l.startswith("Endpoint = ") else l for l in dead.split("\n"))
            (tmp / "dead.conf").write_text(dead)
            run("failclosed: unreachable WireGuard peer, no direct fallback", "failclosed", YTMUWG_TEST_PROFILE=str(tmp / "dead.conf"))
            (tmp / "invalid.conf").write_text("[Interface]\nPrivateKey = invalid\n")
            run("failclosed: invalid profile -> engine failed, traffic blocked", "failclosed",
                YTMUWG_TEST_PROFILE=str(tmp / "invalid.conf"), YTMUWG_EXPECT_FAILED="1")
            assert DirectHandler.hits == 0, "direct server was contacted"
            direct.shutdown()
        finally:
            peer.terminate()
            peer.wait(timeout=10)

    summary = {
        "platform": f"macOS {subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip()} (Foundation + Network.framework, same proxy API as iOS 17+)",
        "passed": results,
        "diagnostics_sample": report,
        "not_covered": ["iPhone installation and UIKit settings screen", "real YouTube Music binary and Google servers",
                        "music playback, next track, lock-screen playback", "Wi-Fi/cellular switching", "real WireGuard provider"],
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if args.out:
        args.out.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
