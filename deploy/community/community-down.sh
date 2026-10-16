#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Preserve database volumes and the JWT key.
exec docker compose down
