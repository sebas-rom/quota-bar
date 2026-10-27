#!/bin/bash
# Regenerates docs/evidence/*.png from the real SwiftUI views (demo data).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="docs/evidence"

swift build -c release
make app

rm -f "$OUT"/*.png
./QuotaBar.app/Contents/MacOS/QuotaBar --render-evidence "$OUT"
cp Resources/AppIcon-1024.png "$OUT/app-icon.png"

echo "Evidence written to $OUT"
