#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build-app.sh"
pkill -x AIUsageBar 2>/dev/null || true
open "$ROOT_DIR/dist/AIUsageBar.app"
