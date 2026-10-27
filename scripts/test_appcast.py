#!/usr/bin/env python3
"""Deterministic checks for scripts/appcast.py (run in CI)."""

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "appcast.py")
NS = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def run(out, *args, existing=None, expect=0):
    cmd = [sys.executable, SCRIPT, "--out", out, *args]
    if existing:
        cmd += ["--existing", existing]
    result = subprocess.run(cmd, capture_output=True, text=True)
    assert result.returncode == expect, f"exit {result.returncode} != {expect}\n{result.stderr}"
    return result


def items(path):
    tree = ET.parse(path)
    return tree.getroot().findall(".//item")


def item(build, short, channel, url):
    return [
        "--version", build, "--short", short, "--channel", channel,
        "--signature", "sig", "--length", "10", "--url", url, "--title", f"v{build}",
    ]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        feed = os.path.join(tmp, "appcast.xml")

        run(feed, *item("20260101000000", "0.4.1", "stable", "https://e/1.zip"))
        assert len(items(feed)) == 1

        # Duplicate build is replaced, not appended.
        run(feed, *item("20260101000000", "0.4.1", "stable", "https://e/1.zip"), existing=feed)
        assert len(items(feed)) == 1

        # Only the newest nightly is advertised, stable history stays.
        run(feed, *item("20260102000000", "0.4.1", "nightly", "https://e/n1.zip"), existing=feed)
        run(feed, *item("20260103000000", "0.4.1", "nightly", "https://e/n2.zip"), existing=feed)
        nightly = [i for i in items(feed) if i.findtext("s:channel", namespaces=NS) == "nightly"]
        stable = [i for i in items(feed) if i.findtext("s:channel", namespaces=NS) is None]
        assert len(nightly) == 1 and nightly[0].findtext("s:version", namespaces=NS) == "20260103000000"
        assert len(stable) == 1

        # Stable retention caps at 10 after insertion.
        for n in range(11):
            build = f"2026011{n}000000"
            run(feed, *item(build, "0.4.1", "stable", f"https://e/s{n}.zip"), existing=feed)
        assert len([i for i in items(feed) if i.findtext("s:channel", namespaces=NS) is None]) == 10

        # Refuse to invent a feed when one is expected but missing.
        missing = os.path.join(tmp, "missing.xml")
        result = run(os.path.join(tmp, "unused.xml"), *item("20260101999999", "0.4.1", "stable", "https://e/x.zip"),
                     existing=missing, expect=1, *["--require-existing"])
        assert "refusing to create" in result.stderr

        # Refuse to overwrite a malformed feed.
        bad = os.path.join(tmp, "bad.xml")
        with open(bad, "w") as fh:
            fh.write("<rss><channel><item>")
        result = run(os.path.join(tmp, "unused2.xml"), *item("20260101999999", "0.4.1", "stable", "https://e/x.zip"),
                     existing=bad, expect=1, *["--require-existing"])
        assert "malformed" in result.stderr

        # require-existing with a valid feed is accepted.
        run(feed, *item("20260102000001", "0.4.1", "stable", "https://e/ok.zip"),
            existing=feed, *["--require-existing"])

    print("appcast tests: ok")


if __name__ == "__main__":
    main()
