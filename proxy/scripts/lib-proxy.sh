# shellcheck shell=bash
set -euo pipefail

PROXY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${PROXY_COMPOSE_FILE:-$PROXY_ROOT/docker-compose.yaml}"
ENV_FILE="${PROXY_ENV_FILE:-$PROXY_ROOT/.env.proxy}"
TEMPLATE_DIR="$PROXY_ROOT/templates"
ENABLED_TEMPLATE_DIR="$PROXY_ROOT/templates-enabled"

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
    else
        echo "请安装 Docker Compose V2（docker compose）或 docker-compose。" >&2
        return 1
    fi
}

env_value() {
    local key="$1"
    local default="${2:-}"
    local line value

    line="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE" 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
        printf '%s' "$default"
        return
    fi

    value="${line%$'\r'}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "$value"
}

ensure_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "找不到环境变量文件：$ENV_FILE" >&2
        return 1
    fi
}

ensure_proxy_network() {
    local network
    network="$(env_value PROXY_NETWORK shared_proxy)"

    if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create "$network" >/dev/null
        echo "已创建 Docker network：$network"
    fi
}

enable_http_templates() {
    rm -rf "$ENABLED_TEMPLATE_DIR"
    mkdir -p "$ENABLED_TEMPLATE_DIR"
    cp "$TEMPLATE_DIR/05-upstreams.conf.template" "$ENABLED_TEMPLATE_DIR/"
    cp "$TEMPLATE_DIR/10-http.conf.template" "$ENABLED_TEMPLATE_DIR/"
}

enable_https_templates() {
    rm -rf "$ENABLED_TEMPLATE_DIR"
    mkdir -p "$ENABLED_TEMPLATE_DIR"
    cp "$TEMPLATE_DIR/05-upstreams.conf.template" "$ENABLED_TEMPLATE_DIR/"
    cp "$TEMPLATE_DIR/10-http-redirect.conf.template" "$ENABLED_TEMPLATE_DIR/10-http.conf.template"
    cp "$TEMPLATE_DIR/20-https.conf.template" "$ENABLED_TEMPLATE_DIR/"
}

render_templates_in_nginx() {
    compose_cmd exec nginx sh -c "set -eu; \
        for tpl in /etc/nginx/templates/*.template; do \
            [ -e \"\$tpl\" ] || continue; \
            out=\"/etc/nginx/conf.d/\$(basename \"\$tpl\" .template)\"; \
            envsubst '\${DOMAIN_WWW} \${DOMAIN_HT} \${DOMAIN_WWW_CERT_NAME} \${DOMAIN_HT_CERT_NAME} \${WEB_UPSTREAM} \${ADMIN_UPSTREAM} \${CERT_NAME}' < \"\$tpl\" > \"\$out\"; \
        done; \
        nginx -t"
}

reload_nginx() {
    render_templates_in_nginx
    compose_cmd exec nginx nginx -s reload
}

certbot_domain_args() {
    local domains_raw domain
    domains_raw="$(env_value CERTBOT_DOMAINS "")"

    if [[ -z "$domains_raw" ]]; then
        domains_raw="$(env_value DOMAIN_WWW "") $(env_value DOMAIN_HT "")"
    fi

    domains_raw="${domains_raw//,/ }"
    for domain in $domains_raw; do
        [[ -n "$domain" ]] && printf -- ' -d %q' "$domain"
    done
}
