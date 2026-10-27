#!/usr/bin/env python3
"""Maintain the QuotaBar Sparkle appcast.

Keeps one feed for both channels:
  * stable items have no <sparkle:channel>
  * nightly items carry <sparkle:channel>nightly</sparkle:channel>

Only the newest nightly is advertised; stable history is kept (capped) so a
rollback target exists.
"""

import argparse
import datetime
import os
import xml.etree.ElementTree as ET
from typing import Optional

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)

MAX_STABLE = 10


def q(name: str) -> str:
    return f"{{{NS}}}{name}"


def skeleton() -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "QuotaBar"
    ET.SubElement(channel, "link").text = "https://github.com/sebas-rom/quota-bar"
    ET.SubElement(channel, "description").text = "QuotaBar updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def channel_node(tree: ET.ElementTree) -> ET.Element:
    node = tree.getroot().find("channel")
    if node is None:
        raise SystemExit("appcast has no <channel>")
    return node


def item_version(item: ET.Element) -> Optional[str]:
    v = item.find(q("version"))
    return v.text.strip() if v is not None and v.text else None


def is_nightly(item: ET.Element) -> bool:
    c = item.find(q("channel"))
    return c is not None and (c.text or "").strip() == "nightly"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--existing", help="existing appcast (may be absent or empty)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--version", required=True, help="CFBundleVersion (build)")
    ap.add_argument("--short", required=True, help="CFBundleShortVersionString")
    ap.add_argument("--channel", choices=["stable", "nightly"], required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--minimum", default="13.0")
    args = ap.parse_args()

    if args.existing and os.path.exists(args.existing) and os.path.getsize(args.existing) > 0:
        try:
            tree = ET.parse(args.existing)
        except ET.ParseError:
            tree = skeleton()
    else:
        tree = skeleton()

    channel = channel_node(tree)
    items = [i for i in channel.findall("item")]

    # Drop anything with the same build number (idempotent re-runs).
    items = [i for i in items if item_version(i) != args.version]
    if args.channel == "nightly":
        items = [i for i in items if not is_nightly(i)]

    # Cap stable history.
    stable_items = [i for i in items if not is_nightly(i)]
    if len(stable_items) > MAX_STABLE:
        drop = set(id(i) for i in stable_items[:-MAX_STABLE])
        items = [i for i in items if id(i) not in drop]

    for item in items:
        channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.title
    now = datetime.datetime.now(datetime.timezone.utc)
    ET.SubElement(item, "pubDate").text = now.strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, q("version")).text = args.version
    ET.SubElement(item, q("shortVersionString")).text = args.short
    if args.channel == "nightly":
        ET.SubElement(item, q("channel")).text = "nightly"
    ET.SubElement(item, q("minimumSystemVersion")).text = args.minimum
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        q("edSignature"): args.signature,
    })

    # Keep channel metadata first, then items (newest first for humans;
    # Sparkle picks by version regardless).
    insert_at = 0
    for index, child in enumerate(list(channel)):
        if child.tag != "item":
            insert_at = index + 1
    channel.insert(insert_at, item)
    for existing in items:
        channel.append(existing)

    ET.indent(tree, space="  ")
    tree.write(args.out, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {args.channel} {args.short} ({args.version}) -> {args.out}")


if __name__ == "__main__":
    main()
