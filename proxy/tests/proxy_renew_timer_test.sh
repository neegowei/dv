#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
SYSTEMD_DIR="$TMP_DIR/systemd"
SBIN_DIR="$TMP_DIR/sbin"
SYSTEMCTL_CALLS="$TMP_DIR/systemctl-calls.log"
mkdir -p "$FAKE_BIN" "$SYSTEMD_DIR" "$SBIN_DIR"
: >"$SYSTEMCTL_CALLS"

cat >"$FAKE_BIN/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
exit 0
FAKE_SYSTEMCTL
chmod +x "$FAKE_BIN/systemctl"

env_file="$TMP_DIR/.env.proxy"
cat >"$env_file" <<'ENV'
CERTBOT_EMAIL=admin@example.test
CERTBOT_DOMAINS=www.example.test,admin.example.test
ENV

assert_file_contains() {
    local file="$1"
    local expected="$2"

    if ! grep -F -- "$expected" "$file" >/dev/null; then
        echo "expected $file to contain: $expected" >&2
        echo "actual:" >&2
        cat "$file" >&2
        exit 1
    fi
}

PATH="$FAKE_BIN:$PATH" \
SYSTEMCTL_CALLS="$SYSTEMCTL_CALLS" \
PROXY_ENV_FILE="$env_file" \
PROXY_RENEW_SCRIPT_PATH="$SBIN_DIR/dv-proxy-renew.sh" \
PROXY_SYSTEMD_DIR="$SYSTEMD_DIR" \
SYSTEMCTL_CMD="$FAKE_BIN/systemctl" \
"$ROOT/scripts/install-renew-timer.sh" install >/dev/null

bash -n "$SBIN_DIR/dv-proxy-renew.sh"
assert_file_contains "$SBIN_DIR/dv-proxy-renew.sh" "PROXY_DIR=\"\${PROXY_DIR:-$ROOT}\""
assert_file_contains "$SBIN_DIR/dv-proxy-renew.sh" "./scripts/proxy.sh renew"
assert_file_contains "$SBIN_DIR/dv-proxy-renew.sh" "certbot renew --dry-run"
assert_file_contains "$SYSTEMD_DIR/dv-proxy-renew.service" "ExecStart=$SBIN_DIR/dv-proxy-renew.sh renew"
assert_file_contains "$SYSTEMD_DIR/dv-proxy-renew.timer" "OnCalendar=*-*-* 03,15:12:00"
assert_file_contains "$SYSTEMD_DIR/dv-proxy-renew.timer" "RandomizedDelaySec=1h"
assert_file_contains "$SYSTEMD_DIR/dv-proxy-renew.timer" "Persistent=true"
assert_file_contains "$SYSTEMCTL_CALLS" "daemon-reload"
assert_file_contains "$SYSTEMCTL_CALLS" "enable --now dv-proxy-renew.timer"

runtime_dir="$TMP_DIR/proxy-runtime"
mkdir -p "$runtime_dir/scripts"
cat >"$runtime_dir/scripts/proxy.sh" <<'FAKE_PROXY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PROXY_CALLS"
exit "${PROXY_STATUS:-0}"
FAKE_PROXY
chmod +x "$runtime_dir/scripts/proxy.sh"
export PROXY_CALLS="$TMP_DIR/proxy-calls.log"

PROXY_DIR="$runtime_dir" PROXY_ENV_FILE="$env_file" \
    PROXY_COMPOSE_FILE="$ROOT/docker-compose.yaml" \
    "$SBIN_DIR/dv-proxy-renew.sh" renew >/dev/null
[[ "$(cat "$PROXY_CALLS")" == renew ]]

if PROXY_STATUS=6 PROXY_DIR="$runtime_dir" PROXY_ENV_FILE="$env_file" \
    PROXY_COMPOSE_FILE="$ROOT/docker-compose.yaml" \
    "$SBIN_DIR/dv-proxy-renew.sh" renew >/dev/null; then
    echo "expected renewal wrapper to propagate proxy.sh failure" >&2
    exit 1
else
    [[ "$?" -eq 6 ]]
fi
