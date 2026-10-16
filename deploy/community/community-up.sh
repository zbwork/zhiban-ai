#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f .env ]] || { echo 'Copy .env.example to .env and set POSTGRES_PASSWORD (random hex).' >&2; exit 66; }
mkdir -p .local
# Mount only the key file; keep the host directory inaccessible to other users.
if [[ ! -f .local/jwt.pem ]]; then
  (umask 077; openssl genpkey -algorithm ED25519 -out .local/jwt.pem)
fi
# Container UID 10001 needs read access; directory restricts other host users.
chmod 700 .local
chmod 644 .local/jwt.pem
exec docker compose up --build -d
