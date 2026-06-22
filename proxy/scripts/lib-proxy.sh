# shellcheck shell=bash
set -euo pipefail

PROXY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${PROXY_COMPOSE_FILE:-$PROXY_ROOT/docker-compose.yaml}"
ENV_FILE="${PROXY_ENV_FILE:-$PROXY_ROOT/.env.proxy}"
TEMPLATE_DIR="${PROXY_TEMPLATE_DIR:-$PROXY_ROOT/templates}"
ENABLED_TEMPLATE_DIR="${PROXY_ENABLED_TEMPLATE_DIR:-$PROXY_ROOT/templates-enabled}"
RENDERED_CONF_DIR="${PROXY_RENDERED_CONF_DIR:-$PROXY_ROOT/conf.d-enabled}"

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

reset_enabled_templates() {
    rm -rf "$ENABLED_TEMPLATE_DIR"
    mkdir -p "$ENABLED_TEMPLATE_DIR"
}

copy_templates() {
    local template

    mkdir -p "$ENABLED_TEMPLATE_DIR"
    for template in "$@"; do
        cp "$TEMPLATE_DIR/$template" "$ENABLED_TEMPLATE_DIR/"
    done
}

enabled_templates_exist() {
    compgen -G "$ENABLED_TEMPLATE_DIR/*.template" >/dev/null
}

enable_infra_http_templates() {
    reset_enabled_templates
    copy_templates \
        "05-infra-upstreams.conf.template" \
        "10-http-infra.conf.template"
}

ensure_http_templates() {
    if enabled_templates_exist; then
        return
    fi

    enable_infra_http_templates
}

enable_infra_https_templates() {
    reset_enabled_templates
    copy_templates \
        "05-infra-upstreams.conf.template" \
        "10-http-redirect-infra.conf.template" \
        "20-https-infra.conf.template"
}

# 从 .env 安全解析 KEY=VALUE 后 export —— 不 source，避免 .env 中混入的 shell 语法
# （$(...)、反引号、; 命令）被执行；且仅 export 白名单（模板引用到的变量）内的 key，
# 避免 PATH/IFS/LD_PRELOAD 等无关变量污染随后的 mkdir/envsubst/cp 等渲染命令。
# 参数：以空格分隔的允许变量名列表（不带 $）。无参数时不 export 任何变量。
export_env_from_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi
  local allow=" $* "
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ "$allow" == *" $key "* ]] || continue
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    export "$key=$val"
  done <"$ENV_FILE"
}

template_envsubst_vars() {
  local tpl match var
  local vars=()
  declare -A seen=()

  for tpl in "$ENABLED_TEMPLATE_DIR"/*.template; do
    [[ -e "$tpl" ]] || continue
    while IFS= read -r match; do
      var="${match#\$\{}"
      var="${var%\}}"
      if [[ -z "${seen[$var]:-}" ]]; then
        seen[$var]=1
        vars+=("\$$var")
      fi
    done < <(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tpl" || true)
  done

  local IFS=' '
  printf '%s' "${vars[*]}"
}

render_templates_on_host() {
  local tpl out envsubst_vars

  if ! command -v envsubst >/dev/null 2>&1; then
    echo "请安装 gettext（提供 envsubst 命令）。" >&2
    return 1
  fi

  # 先算出模板引用的变量（此时 PATH 等仍干净），仅以这些变量为白名单 export，
  # 避免 .env 里的 PATH/IFS 等污染下面的 mkdir/rm/envsubst。
  envsubst_vars="$(template_envsubst_vars)"
  export_env_from_file ${envsubst_vars//\$/}
  mkdir -p "$RENDERED_CONF_DIR"
  rm -f "$RENDERED_CONF_DIR"/*.conf

  for tpl in "$ENABLED_TEMPLATE_DIR"/*.template; do
    [[ -e "$tpl" ]] || continue
    out="$RENDERED_CONF_DIR/$(basename "$tpl" .template)"
    if [[ -n "$envsubst_vars" ]]; then
      envsubst "$envsubst_vars" <"$tpl" >"$out"
    else
      cp "$tpl" "$out"
    fi
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
