#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi

if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
    exit 0
fi

printf '%s\n' "$*" >>"$DOCKER_CALLS"
exit 0
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

ENV_FILE="$TMP_DIR/.env.proxy"
cat >"$ENV_FILE" <<'ENV'
CERTBOT_EMAIL=admin@example.test
CERTBOT_STAGING=0
CERTBOT_DOMAINS=www.example.test,admin.example.test
ENV

export PATH="$FAKE_BIN:$PATH"
export DOCKER_CALLS="$TMP_DIR/docker-calls.log"
export PROXY_ENV_FILE="$ENV_FILE"
export PROXY_COMPOSE_FILE="$ROOT/docker-compose.yaml"

"$ROOT/scripts/proxy.sh" issue-domain app.example.test >/dev/null

if ! grep -F -- "--cert-name app.example.test" "$DOCKER_CALLS" >/dev/null; then
    echo "expected issue-domain to use the domain as cert-name" >&2
    exit 1
fi

if ! grep -F -- "-d app.example.test" "$DOCKER_CALLS" >/dev/null; then
    echo "expected issue-domain to request only the provided domain" >&2
    exit 1
fi

if grep -F -- "-d www.example.test" "$DOCKER_CALLS" >/dev/null; then
    echo "expected issue-domain not to use CERTBOT_DOMAINS" >&2
    exit 1
fi
