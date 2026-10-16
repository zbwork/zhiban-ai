#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Credentials are one JSON object on stdin; never argv or logs.
exec docker compose --profile bootstrap run --rm -T bootstrap
