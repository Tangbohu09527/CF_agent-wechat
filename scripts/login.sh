#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

cat >&2 <<'EOF'
Notice: login.sh is a compatibility wrapper. Production login always runs the
forced fresh QR lifecycle through start-qr-login.sh.
EOF

exec "${SCRIPT_DIR}/start-qr-login.sh" "$@"
