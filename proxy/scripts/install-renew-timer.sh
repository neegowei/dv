#!/usr/bin/env bash
# Optionally install a systemd timer for shared proxy certificate renewal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-proxy.sh
source "$SCRIPT_DIR/lib-proxy.sh"

UNIT_NAME="${PROXY_RENEW_UNIT_NAME:-dv-proxy-renew}"
RENEW_SCRIPT_PATH="${PROXY_RENEW_SCRIPT_PATH:-/usr/local/sbin/${UNIT_NAME}.sh}"
SYSTEMD_DIR="${PROXY_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL_CMD="${SYSTEMCTL_CMD:-systemctl}"
RENEW_ON_CALENDAR="${PROXY_RENEW_ON_CALENDAR:-*-*-* 03,15:12:00}"
RENEW_RANDOMIZED_DELAY_SEC="${PROXY_RENEW_RANDOMIZED_DELAY_SEC:-1h}"

need_root_for_default_paths() {
    [[ "$RENEW_SCRIPT_PATH" == /usr/* || "$SYSTEMD_DIR" == /etc/* ]]
}

require_root_if_needed() {
    if need_root_for_default_paths && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "安装 systemd 续签服务需要 root 权限；请使用 sudo 重新执行。" >&2
        exit 1
    fi
}

write_renew_script() {
    mkdir -p "$(dirname "$RENEW_SCRIPT_PATH")"
    cat >"$RENEW_SCRIPT_PATH" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

PROXY_DIR="\${PROXY_DIR:-$PROXY_ROOT}"
ENV_FILE="\${PROXY_ENV_FILE:-\$PROXY_DIR/.env.proxy}"
COMPOSE_FILE="\${PROXY_COMPOSE_FILE:-\$PROXY_DIR/docker-compose.yaml}"

log() {
    printf '[%s] %s\\n' "\$(date -Is)" "\$*"
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose --env-file "\$ENV_FILE" -f "\$COMPOSE_FILE" "\$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "\$ENV_FILE" -f "\$COMPOSE_FILE" "\$@"
    else
        log "Docker Compose is not installed" >&2
        exit 1
    fi
}

if [[ ! -d "\$PROXY_DIR" ]]; then
    log "missing proxy dir: \$PROXY_DIR" >&2
    exit 1
fi
if [[ ! -f "\$ENV_FILE" ]]; then
    log "missing env file: \$ENV_FILE" >&2
    exit 1
fi
if [[ ! -f "\$COMPOSE_FILE" ]]; then
    log "missing compose file: \$COMPOSE_FILE" >&2
    exit 1
fi

cd "\$PROXY_DIR"

case "\${1:-renew}" in
    renew)
        log "starting certificate renewal through dv/proxy"
        PROXY_ENV_FILE="\$ENV_FILE" PROXY_COMPOSE_FILE="\$COMPOSE_FILE" ./scripts/proxy.sh renew
        PROXY_ENV_FILE="\$ENV_FILE" PROXY_COMPOSE_FILE="\$COMPOSE_FILE" ./scripts/proxy.sh test
        log "certificate renewal finished"
        ;;
    dry-run)
        log "starting certbot renewal dry-run through dv/proxy compose"
        compose run --rm certbot renew --dry-run --webroot -w /var/www/certbot
        PROXY_ENV_FILE="\$ENV_FILE" PROXY_COMPOSE_FILE="\$COMPOSE_FILE" ./scripts/proxy.sh test
        log "certbot renewal dry-run finished"
        ;;
    *)
        echo "Usage: \$0 [renew|dry-run]" >&2
        exit 64
        ;;
esac
SCRIPT
    chmod 0755 "$RENEW_SCRIPT_PATH"
}

write_systemd_units() {
    mkdir -p "$SYSTEMD_DIR"
    cat >"$SYSTEMD_DIR/${UNIT_NAME}.service" <<SERVICE
[Unit]
Description=Renew Let's Encrypt certificates for dv proxy
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$RENEW_SCRIPT_PATH renew
SERVICE

    cat >"$SYSTEMD_DIR/${UNIT_NAME}.timer" <<TIMER
[Unit]
Description=Run dv proxy certificate renewal twice daily

[Timer]
OnCalendar=$RENEW_ON_CALENDAR
RandomizedDelaySec=$RENEW_RANDOMIZED_DELAY_SEC
Persistent=true
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
TIMER
}

install_timer() {
    require_root_if_needed
    ensure_env_file
    write_renew_script
    bash -n "$RENEW_SCRIPT_PATH"
    write_systemd_units
    "$SYSTEMCTL_CMD" daemon-reload
    "$SYSTEMCTL_CMD" enable --now "${UNIT_NAME}.timer"

    echo "已安装证书自动续签 timer：${UNIT_NAME}.timer"
    echo "续签脚本：$RENEW_SCRIPT_PATH"
    echo "手动 dry-run：$RENEW_SCRIPT_PATH dry-run"
    "$SYSTEMCTL_CMD" list-timers --all "${UNIT_NAME}.timer" || true
}

case "${1:-install}" in
    install)
        install_timer
        ;;
    *)
        echo "用法：$0 [install]" >&2
        exit 64
        ;;
esac
