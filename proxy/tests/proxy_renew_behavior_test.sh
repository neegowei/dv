#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/hook runtime"
export REAL_TOUCH="$(command -v touch)"

cat >"$FAKE_BIN/touch" <<'FAKE_TOUCH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "$HOOK_MOUNT_TARGET/"* ]]
"$REAL_TOUCH" "$HOOK_MOUNT_SOURCE/${1#"$HOOK_MOUNT_TARGET/"}"
FAKE_TOUCH

cat >"$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == compose ]]
shift
if [[ "${1:-}" == version ]]; then
    exit 0
fi
[[ "$1" == --env-file ]]
shift 2
[[ "$1" == -f ]]
shift 2

case "$1" in
    run)
        printf 'certbot-renew\n' >>"$DOCKER_CALLS"
        hook=""
        while (($#)); do
            case "$1" in
                --volume)
                    export HOOK_MOUNT_SOURCE="${2%:*}"
                    export HOOK_MOUNT_TARGET="${2##*:}"
                    printf '%s\n' "$HOOK_MOUNT_SOURCE" >"$HOOK_DIR_RECORD"
                    shift 2
                    ;;
                --deploy-hook)
                    hook="$2"
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        for ((i = 0; i < SIM_RENEWED_COUNT; i++)); do
            if [[ -n "$hook" ]]; then
                sh -c "$hook"
            fi
        done
        exit "$SIM_CERTBOT_STATUS"
        ;;
    exec)
        shift
        [[ "$1" == nginx && "$2" == nginx ]]
        shift 2
        case "$*" in
            -t)
                printf 'nginx-test\n' >>"$DOCKER_CALLS"
                exit "$SIM_NGINX_TEST_STATUS"
                ;;
            '-s reload')
                printf 'nginx-reload\n' >>"$DOCKER_CALLS"
                exit "$SIM_NGINX_RELOAD_STATUS"
                ;;
            *) exit 90 ;;
        esac
        ;;
    *) exit 91 ;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/touch"

export PATH="$FAKE_BIN:$PATH"
export TMPDIR="$TMP_DIR/hook runtime"
export DOCKER_CALLS="$TMP_DIR/docker-calls.log"
export HOOK_DIR_RECORD="$TMP_DIR/hook-dir.log"
export PROXY_ENV_FILE="$TMP_DIR/.env.proxy"
export PROXY_COMPOSE_FILE="$ROOT/docker-compose.yaml"
export PROXY_ENABLED_TEMPLATE_DIR="$TMP_DIR/templates-enabled"
export PROXY_RENDERED_CONF_DIR="$TMP_DIR/conf.d-enabled"
mkdir -p "$PROXY_ENABLED_TEMPLATE_DIR" "$PROXY_RENDERED_CONF_DIR"
printf 'PROXY_NETWORK=shared_proxy\n' >"$PROXY_ENV_FILE"

assert_calls() {
    local action="$1" expected="$2" actual
    actual="$(grep -cFx "$action" "$DOCKER_CALLS" || true)"
    if [[ "$actual" != "$expected" ]]; then
        echo "expected $expected $action calls, got $actual" >&2
        cat "$DOCKER_CALLS" >&2
        exit 1
    fi
}

run_case() {
    local name="$1" renewed="$2" certbot_status="$3" test_status="$4"
    local reload_status="$5" expected_status="$6" expected_tests="$7" expected_reloads="$8"
    local status before

    : >"$DOCKER_CALLS"
    rm -f "$HOOK_DIR_RECORD"
    printf '# active site routing\n' >"$PROXY_RENDERED_CONF_DIR/60-https.conf"
    printf '# stale site routing\n' >"$PROXY_ENABLED_TEMPLATE_DIR/60-https.conf.template"
    printf '# pending new site\n' >"$PROXY_ENABLED_TEMPLATE_DIR/90-new.conf.template"
    before="$(stat -c '%i:%y:%s:%a' "$PROXY_RENDERED_CONF_DIR/60-https.conf")"

    if SIM_RENEWED_COUNT="$renewed" SIM_CERTBOT_STATUS="$certbot_status" \
        SIM_NGINX_TEST_STATUS="$test_status" SIM_NGINX_RELOAD_STATUS="$reload_status" \
        "$ROOT/scripts/proxy.sh" renew >"$TMP_DIR/renew.out" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" != "$expected_status" ]]; then
        echo "$name: expected status $expected_status, got $status" >&2
        cat "$TMP_DIR/renew.out" >&2
        exit 1
    fi

    assert_calls certbot-renew 1
    assert_calls nginx-test "$expected_tests"
    assert_calls nginx-reload "$expected_reloads"
    [[ "$(cat "$PROXY_RENDERED_CONF_DIR/60-https.conf")" == '# active site routing' ]]
    [[ "$(stat -c '%i:%y:%s:%a' "$PROXY_RENDERED_CONF_DIR/60-https.conf")" == "$before" ]]
    [[ ! -e "$PROXY_RENDERED_CONF_DIR/90-new.conf" ]]
    [[ "$(cat "$PROXY_ENABLED_TEMPLATE_DIR/60-https.conf.template")" == '# stale site routing' ]]
    if [[ -f "$HOOK_DIR_RECORD" ]]; then
        [[ ! -e "$(cat "$HOOK_DIR_RECORD")" ]]
    fi
    [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
    printf 'PASS %s\n' "$name"
}

run_case no-renewal           0 0 0 0 0 0 0
run_case successful-renewal   1 0 0 0 0 1 1
run_case multiple-renewals    2 0 0 0 0 1 1
run_case failed-renewal       0 1 0 0 1 0 0
run_case partial-renewal      1 1 0 0 1 1 1
run_case nginx-check-failure  1 0 7 0 7 1 0
run_case nginx-reload-failure 1 0 0 8 8 1 1
