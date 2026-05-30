#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-proxy.sh
source "$SCRIPT_DIR/lib-proxy.sh"

usage() {
    cat <<'USAGE'
用法：
  proxy.sh up       创建 proxy network 并启动 nginx（首次签证前为 HTTP 反代）
  proxy.sh issue    使用 certbot webroot 申请证书，成功后切换 HTTPS 配置并 reload nginx
  proxy.sh issue-domain <domain>
                    为单个域名单独申请证书，证书名同域名；不会切换 HTTPS 配置
  proxy.sh expand   使用 CERTBOT_DOMAINS 扩展已有证书，成功后 reload nginx
  proxy.sh renew    续期证书，成功后 reload nginx
  proxy.sh enable-https
                    启用基础设施 HTTPS 模板（一域一证）并 reload，不重新申请证书
  proxy.sh reload   重新渲染当前启用模板并 reload nginx
  proxy.sh test     重新渲染当前启用模板并执行 nginx -t
  proxy.sh ps       查看 proxy services 状态
  proxy.sh logs     跟踪 nginx/certbot 日志
  proxy.sh down     停止 proxy services

可选：
  PROXY_ENV_FILE=/path/.env.proxy proxy.sh up
USAGE
}

require_certbot_email() {
    local email
    email="$(env_value CERTBOT_EMAIL "")"
    if [[ -z "$email" || "$email" == "admin@example.com" ]]; then
        echo "请先在 $ENV_FILE 中设置 CERTBOT_EMAIL。" >&2
        return 1
    fi
}

domain_args() {
    local domains_raw domain
    domains_raw="$(env_value CERTBOT_DOMAINS "")"

    if [[ -z "$domains_raw" ]]; then
        domains_raw="$(env_value DOMAIN_WWW "") $(env_value DOMAIN_ADMIN "")"
    fi

    domains_raw="${domains_raw//,/ }"
    for domain in $domains_raw; do
        [[ -n "$domain" ]] && CERTBOT_DOMAIN_ARGS+=("-d" "$domain")
    done
}

cmd="${1:-help}"

case "$cmd" in
    up)
        ensure_env_file
        ensure_proxy_network
        enable_http_templates
        compose_cmd up -d nginx
        ;;
    issue)
        ensure_env_file
        require_certbot_email
        ensure_proxy_network
        CERTBOT_DOMAIN_ARGS=()
        domain_args
        if [[ "${#CERTBOT_DOMAIN_ARGS[@]}" -eq 0 ]]; then
            echo "请在 $ENV_FILE 中设置 CERTBOT_DOMAINS 或 DOMAIN_WWW/DOMAIN_ADMIN。" >&2
            exit 1
        fi

        extra_args=()
        if [[ "$(env_value CERTBOT_STAGING 0)" == "1" ]]; then
            extra_args+=(--test-cert)
            echo "使用 Let's Encrypt Staging（CERTBOT_STAGING=1）。"
        fi

        cert_name="$(env_value CERT_NAME "$(env_value DOMAIN_WWW "")")"
        email="$(env_value CERTBOT_EMAIL "")"

        compose_cmd run --rm certbot certonly \
            --webroot -w /var/www/certbot \
            --email "$email" \
            --agree-tos --no-eff-email \
            --cert-name "$cert_name" \
            "${extra_args[@]}" \
            "${CERTBOT_DOMAIN_ARGS[@]}"

        enable_https_templates
        reload_nginx
        echo "证书与 HTTPS 配置已生效。证书路径：/etc/letsencrypt/live/$cert_name/"
        ;;
    issue-domain)
        ensure_env_file
        require_certbot_email
        ensure_proxy_network

        domain="${2:-}"
        if [[ -z "$domain" ]]; then
            echo "用法：proxy.sh issue-domain <domain>" >&2
            exit 1
        fi

        extra_args=()
        if [[ "$(env_value CERTBOT_STAGING 0)" == "1" ]]; then
            extra_args+=(--test-cert)
            echo "使用 Let's Encrypt Staging（CERTBOT_STAGING=1）。"
        fi

        email="$(env_value CERTBOT_EMAIL "")"

        compose_cmd run --rm certbot certonly \
            --webroot -w /var/www/certbot \
            --email "$email" \
            --agree-tos --no-eff-email \
            --cert-name "$domain" \
            "${extra_args[@]}" \
            -d "$domain"

        echo "单域名证书已签发。证书路径：/etc/letsencrypt/live/$domain/"
        ;;
    expand)
        ensure_env_file
        require_certbot_email
        ensure_proxy_network
        CERTBOT_DOMAIN_ARGS=()
        domain_args
        if [[ "${#CERTBOT_DOMAIN_ARGS[@]}" -eq 0 ]]; then
            echo "请在 $ENV_FILE 中设置 CERTBOT_DOMAINS 或 DOMAIN_WWW/DOMAIN_ADMIN。" >&2
            exit 1
        fi

        extra_args=()
        if [[ "$(env_value CERTBOT_STAGING 0)" == "1" ]]; then
            extra_args+=(--test-cert)
            echo "使用 Let's Encrypt Staging（CERTBOT_STAGING=1）。"
        fi

        cert_name="$(env_value CERT_NAME "$(env_value DOMAIN_WWW "")")"
        email="$(env_value CERTBOT_EMAIL "")"

        compose_cmd run --rm certbot certonly \
            --webroot -w /var/www/certbot \
            --email "$email" \
            --agree-tos --no-eff-email \
            --expand \
            --cert-name "$cert_name" \
            "${extra_args[@]}" \
            "${CERTBOT_DOMAIN_ARGS[@]}"

        reload_nginx
        echo "证书已扩展并重新加载 nginx。证书路径：/etc/letsencrypt/live/$cert_name/"
        ;;
    renew)
        ensure_env_file
        compose_cmd run --rm certbot renew --webroot -w /var/www/certbot
        reload_nginx
        ;;
    enable-https)
        ensure_env_file
        ensure_proxy_network
        enable_infra_https_templates
        reload_nginx
        echo "基础设施 HTTPS 已启用（monitor / store / admin.store）。"
        ;;
    reload)
        ensure_env_file
        reload_nginx
        ;;
    test)
        ensure_env_file
        render_templates_in_nginx
        ;;
    ps)
        ensure_env_file
        compose_cmd ps
        ;;
    logs)
        ensure_env_file
        compose_cmd logs -f
        ;;
    down)
        ensure_env_file
        compose_cmd down
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
