#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

# 运行态目录隔离到 TMP_DIR：测试经 PROXY_ENABLED_TEMPLATE_DIR / PROXY_RENDERED_CONF_DIR
# 让 lib-proxy.sh 把模板渲染落到这里，避免 reset/cleanup 误删仓库内真实的
# templates-enabled/ 与 conf.d-enabled/。
ENABLED_DIR="$TMP_DIR/templates-enabled"
CONF_DIR="$TMP_DIR/conf.d-enabled"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

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

export PATH="$FAKE_BIN:$PATH"
export DOCKER_CALLS="$TMP_DIR/docker-calls.log"
export PROXY_COMPOSE_FILE="$ROOT/docker-compose.yaml"
export PROXY_ENABLED_TEMPLATE_DIR="$ENABLED_DIR"
export PROXY_RENDERED_CONF_DIR="$CONF_DIR"

reset_runtime_dirs() {
    : >"$DOCKER_CALLS"
    rm -rf "$ENABLED_DIR"
    mkdir -p "$ENABLED_DIR" "$CONF_DIR"
    rm -f "$CONF_DIR"/*.conf
}

write_env() {
    local env_file="$1"
    shift

    : >"$env_file"
    printf '%s\n' "$@" >>"$env_file"
}

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

test_render_scans_custom_template_variables() {
    local env_file="$TMP_DIR/render.env"

    reset_runtime_dirs
    write_env "$env_file" \
        "CUSTOM_DOMAIN=app.example.test" \
        "CUSTOM_UPSTREAM=app:8080"

    cat >"$ENABLED_DIR/90-custom.conf.template" <<'TPL'
server {
    listen 80;
    server_name ${CUSTOM_DOMAIN};

    location / {
        proxy_pass http://${CUSTOM_UPSTREAM};
        proxy_set_header Host $host;
        return 301 https://$host$request_uri;
    }
}
TPL

    PROXY_ENV_FILE="$env_file" "$ROOT/scripts/proxy.sh" reload >/dev/null

    assert_file_contains "$CONF_DIR/90-custom.conf" "server_name app.example.test;"
    assert_file_contains "$CONF_DIR/90-custom.conf" "proxy_pass http://app:8080;"
    assert_file_contains "$CONF_DIR/90-custom.conf" 'proxy_set_header Host $host;'
    assert_file_contains "$CONF_DIR/90-custom.conf" 'return 301 https://$host$request_uri;'
}

test_up_preserves_existing_enabled_templates() {
    local env_file="$TMP_DIR/up.env"

    reset_runtime_dirs
    write_env "$env_file" \
        "PROXY_NETWORK=shared_proxy" \
        "CUSTOM_DOMAIN=up.example.test"
    cat >"$ENABLED_DIR/90-custom.conf.template" <<'TPL'
server {
    listen 80;
    server_name ${CUSTOM_DOMAIN};
}
TPL

    PROXY_ENV_FILE="$env_file" "$ROOT/scripts/proxy.sh" up >/dev/null

    if [[ ! -f "$ENABLED_DIR/90-custom.conf.template" ]]; then
        echo "expected proxy.sh up to preserve existing templates-enabled files" >&2
        exit 1
    fi

    assert_file_contains "$CONF_DIR/90-custom.conf" "server_name up.example.test;"
}

test_issue_requires_certbot_domains_without_legacy_fallback() {
    local env_file="$TMP_DIR/issue-missing-domains.env"
    local output="$TMP_DIR/issue-missing-domains.out"
    local status

    reset_runtime_dirs
    write_env "$env_file" \
        "CERTBOT_EMAIL=admin@example.test" \
        "DOMAIN_WWW=www.example.test" \
        "DOMAIN_HT=admin.example.test"

    set +e
    PROXY_ENV_FILE="$env_file" "$ROOT/scripts/proxy.sh" issue >"$output" 2>&1
    status=$?
    set -e

    if [[ "$status" -eq 0 ]]; then
        echo "expected proxy.sh issue to fail when CERTBOT_DOMAINS is missing" >&2
        exit 1
    fi

    assert_file_contains "$output" "CERTBOT_DOMAINS"
}

test_issue_preserves_templates_and_uses_first_domain_as_cert_name() {
    local env_file="$TMP_DIR/issue.env"

    reset_runtime_dirs
    write_env "$env_file" \
        "CERTBOT_EMAIL=admin@example.test" \
        "CERTBOT_DOMAINS=app.example.test,api.example.test"
    echo "# custom template" >"$ENABLED_DIR/90-custom.conf.template"

    PROXY_ENV_FILE="$env_file" "$ROOT/scripts/proxy.sh" issue >/dev/null

    if [[ ! -f "$ENABLED_DIR/90-custom.conf.template" ]]; then
        echo "expected proxy.sh issue to preserve existing templates-enabled files" >&2
        exit 1
    fi

    if [[ -f "$ENABLED_DIR/20-https.conf.template" ]]; then
        echo "expected proxy.sh issue not to enable legacy frontend/backend HTTPS templates" >&2
        exit 1
    fi

    assert_file_contains "$DOCKER_CALLS" "--cert-name app.example.test"
    assert_file_contains "$DOCKER_CALLS" "-d app.example.test"
    assert_file_contains "$DOCKER_CALLS" "-d api.example.test"
}

test_render_scans_custom_template_variables
test_up_preserves_existing_enabled_templates
test_issue_requires_certbot_domains_without_legacy_fallback
test_issue_preserves_templates_and_uses_first_domain_as_cert_name
