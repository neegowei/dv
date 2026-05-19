# shellcheck shell=bash
set -euo pipefail

PROXY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${PROXY_COMPOSE_FILE:-$PROXY_ROOT/docker-compose.yaml}"
ENV_FILE="${PROXY_ENV_FILE:-$PROXY_ROOT/.env.proxy}"
TEMPLATE_DIR="$PROXY_ROOT/templates"
ENABLED_TEMPLATE_DIR="$PROXY_ROOT/templates-enabled"
RENDERED_CONF_DIR="$PROXY_ROOT/conf.d-enabled"

# Keep in sync with infra / default nginx templates.
ENVSUBST_VARS='$DOMAIN_WWW $DOMAIN_HT $DOMAIN_WWW_CERT_NAME $DOMAIN_HT_CERT_NAME $WEB_UPSTREAM $ADMIN_UPSTREAM $CERT_NAME $DOMAIN_MONITOR $DOMAIN_STORE $DOMAIN_ADMIN_STORE $DOMAIN_MONITOR_CERT_NAME $DOMAIN_STORE_CERT_NAME $DOMAIN_ADMIN_STORE_CERT_NAME $GRAFANA_UPSTREAM $STORE_UPSTREAM $ADMIN_STORE_UPSTREAM'

copy_infra_upstreams() {
    cp "$TEMPLATE_DIR/05-infra-upstreams.conf.template" "$ENABLED_TEMPLATE_DIR/"
}

copy_infra_http_templates() {
    copy_infra_upstreams
    cp "$TEMPLATE_DIR/10-http-infra.conf.template" "$ENABLED_TEMPLATE_DIR/"
}

copy_infra_https_templates() {
    copy_infra_upstreams
    cp "$TEMPLATE_DIR/10-http-redirect-infra.conf.template" "$ENABLED_TEMPLATE_DIR/"
    cp "$TEMPLATE_DIR/20-https-infra.conf.template" "$ENABLED_TEMPLATE_DIR/"
}

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
    copy_infra_http_templates
}

enable_https_templates() {
    rm -rf "$ENABLED_TEMPLATE_DIR"
    mkdir -p "$ENABLED_TEMPLATE_DIR"
    cp "$TEMPLATE_DIR/05-upstreams.conf.template" "$ENABLED_TEMPLATE_DIR/"
    cp "$TEMPLATE_DIR/10-http-redirect.conf.template" "$ENABLED_TEMPLATE_DIR/10-http.conf.template"
    cp "$TEMPLATE_DIR/20-https.conf.template" "$ENABLED_TEMPLATE_DIR/"
    copy_infra_https_templates
}

enable_infra_https_templates() {
    rm -rf "$ENABLED_TEMPLATE_DIR"
    mkdir -p "$ENABLED_TEMPLATE_DIR"
    copy_infra_https_templates
}

export_env_from_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

render_templates_on_host() {
  local tpl out

  if ! command -v envsubst >/dev/null 2>&1; then
    echo "请安装 gettext（提供 envsubst 命令）。" >&2
    return 1
  fi

  export_env_from_file
  mkdir -p "$RENDERED_CONF_DIR"
  rm -f "$RENDERED_CONF_DIR"/*.conf

  for tpl in "$ENABLED_TEMPLATE_DIR"/*.template; do
    [[ -e "$tpl" ]] || continue
    out="$RENDERED_CONF_DIR/$(basename "$tpl" .template)"
    envsubst "$ENVSUBST_VARS" <"$tpl" >"$out"
  done
}

render_templates_in_nginx() {
  render_templates_on_host
  compose_cmd exec nginx nginx -t
}

reload_nginx() {
  render_templates_on_host
  compose_cmd exec nginx nginx -t
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
