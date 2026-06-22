#!/usr/bin/env bash
# 共享基础设施一键初始化与部署脚本
# 覆盖：proxy(nginx)、db、monitor、etcd、rabbitmq、minio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data}"

# path:uid:gid:mode — uid/gid 为空表示 root 属主
# 完整列表在 resolve_logs_owner 中维护（logs 需动态填入部署用户 uid）
declare -a DATA_DIR_SPECS=()

declare -a NETWORKS=(
    shared_proxy
    shared_db
    shared_monitor
    shared_etcd
    shared_rabbitmq
    shared_minio
)

declare -A STACKS=(
    [proxy]="$SCRIPT_DIR/proxy"
    [db]="$SCRIPT_DIR/db"
    [monitor]="$SCRIPT_DIR/monitor"
    [etcd]="$SCRIPT_DIR/etcd"
    [rabbitmq]="$SCRIPT_DIR/rabbitmq"
    [minio]="$SCRIPT_DIR/minio"
)

usage() {
    cat <<'USAGE'
用法：
  deploy-infra.sh init-env [stack ...]
                                     从 .env.*.example 生成缺失的 .env.*（幂等，不覆盖）
  deploy-infra.sh init-data          创建 /data 子目录并设置属主/权限（需 root）
  deploy-infra.sh init-networks      创建 Docker external networks
  deploy-infra.sh init               init-data + init-networks
  deploy-infra.sh validate [stack ...]
                                     校验各 stack 的 .env 是否仍有占位符/空值
  deploy-infra.sh up [stack ...]     校验配置后启动服务（默认全部）
  deploy-infra.sh down [stack ...]   停止服务（默认全部）
  deploy-infra.sh restart [stack ...]
  deploy-infra.sh ps [stack ...]     查看状态
  deploy-infra.sh logs <stack>       跟踪日志

可用 stack：proxy db monitor etcd rabbitmq minio

环境变量：
  DATA_ROOT=/data          数据根目录（默认 /data）
  DEPLOY_UID / DEPLOY_GID  logs 目录属主（默认当前用户，init-data 时 root 下有效）

示例：
  # 1. 准备各 stack 的 .env.* 文件（db/.env.db、monitor/.env.monitor 等）
  # 2. 初始化目录与网络
  sudo ./deploy-infra.sh init
  # 3. 启动全部服务
  ./deploy-infra.sh up
  ./deploy-infra.sh up db monitor
  ./deploy-infra.sh down proxy
USAGE
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "请先安装 Docker。" >&2
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo "请先安装 Docker Compose V2（docker compose）。" >&2
        exit 1
    fi
}

require_root_for_init() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "init-data 需要 root 权限，请使用：sudo $0 init-data" >&2
        exit 1
    fi
}

resolve_logs_owner() {
    local uid gid spec line
    uid="${DEPLOY_UID:-${SUDO_UID:-$(id -u)}}"
    gid="${DEPLOY_GID:-${SUDO_GID:-$(id -g)}}"
    DATA_DIR_SPECS=()
    while IFS= read -r spec; do
        [[ "$spec" == *"__DEPLOY__"* ]] && spec="${spec/__DEPLOY__/${uid}:${gid}}"
        DATA_DIR_SPECS+=("$spec")
    done < <(printf '%s\n' \
        "certbot-www::root:755" \
        "letsencrypt::root:755" \
        "mysql:999:999:750" \
        "redis::root:755" \
        "mongo:999:999:750" \
        "prometheus:65534:65534:750" \
        "loki:10001:10001:750" \
        "tempo:10001:10001:750" \
        "grafana:472:472:750" \
        "logs:__DEPLOY__:755" \
        "etcd::root:755" \
        "rabbitmq:999:999:750" \
        "minio::root:755")
}

apply_dir_spec() {
    local spec="$1"
    local name uid gid mode path

    IFS=':' read -r name uid gid mode <<<"$spec"
    path="${DATA_ROOT}/${name}"

    mkdir -p "$path"

    if [[ -n "$uid" && -n "$gid" ]]; then
        if [[ "$gid" == "root" ]]; then
            chown "$uid" "$path"
        else
            chown "${uid}:${gid}" "$path"
        fi
    elif [[ -n "$uid" && "$gid" == "root" ]]; then
        chown "$uid" "$path"
    fi

    if [[ -n "$mode" ]]; then
        chmod "$mode" "$path"
    fi

    echo "  ${path}  $(stat -c '%U:%G %a' "$path" 2>/dev/null || ls -ld "$path")"
}

cmd_init_data() {
    require_root_for_init
    resolve_logs_owner

    echo "=== 初始化数据目录：${DATA_ROOT} ==="
    mkdir -p "$DATA_ROOT"
    for spec in "${DATA_DIR_SPECS[@]}"; do
        apply_dir_spec "$spec"
    done
    echo "完成。"
}

cmd_init_networks() {
    require_docker
    echo "=== 创建 Docker networks ==="
    for net in "${NETWORKS[@]}"; do
        if docker network inspect "$net" >/dev/null 2>&1; then
            echo "  已存在：$net"
        else
            docker network create "$net" >/dev/null
            echo "  已创建：$net"
        fi
    done
    echo "完成。"
}

cmd_init() {
    cmd_init_data
    cmd_init_networks
}

stack_env_file() {
    local dir="$1"
    local name
    name="$(basename "$dir")"
    echo "${dir}/.env.${name}"
}

compose_file_for() {
    local dir="$1"
    local name
    name="$(basename "$dir")"
    echo "${dir}/docker-compose.yaml"
}

compose_cmd_fixed() {
    local dir="$1"
    shift
    local env_file name
    env_file="$(stack_env_file "$dir")"
    name="$(basename "$dir")"

    if [[ ! -f "$env_file" ]]; then
        echo "找不到环境变量文件：$env_file" >&2
        exit 1
    fi

    if docker compose version >/dev/null 2>&1; then
        docker compose --env-file "$env_file" -f "$(compose_file_for "$dir")" "$@"
    else
        docker-compose --env-file "$env_file" -f "$(compose_file_for "$dir")" "$@"
    fi
}

# ---- .env 引导与校验 ----

# .env.example 中需用户填写真实值的占位前缀；值为空或以此开头视为"未配置"。
PLACEHOLDER_PREFIX="CHANGE_ME"

# 输出 env 文件中值为空或仍为占位符的变量名（每行一个）。
find_placeholder_vars() {
    local file="$1" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        [[ -z "$key" ]] && continue
        if [[ -z "$val" || "$val" == "${PLACEHOLDER_PREFIX}"* ]]; then
            printf '%s\n' "$key"
        fi
    done <"$file"
}

# 缺 .env.<name> 时从 .env.<name>.example 复制；已存在则跳过（幂等，不覆盖真实配置）。
ensure_env_from_example() {
    local dir="$1" env_file example
    env_file="$(stack_env_file "$dir")"
    example="${env_file}.example"

    if [[ -f "$env_file" ]]; then
        echo "  已存在，跳过：$env_file"
        return 0
    fi
    if [[ ! -f "$example" ]]; then
        echo "  ⚠ 缺少示例文件：$example" >&2
        return 1
    fi
    cp "$example" "$env_file"
    echo "  已生成：$env_file（请填写其中的 ${PLACEHOLDER_PREFIX} 占位值）"
    return 0
}

# 校验单个 stack 的 .env：文件需存在，且无空值/占位符变量。
validate_stack_env() {
    local dir="$1" env_file name
    env_file="$(stack_env_file "$dir")"
    name="$(basename "$dir")"

    if [[ ! -f "$env_file" ]]; then
        echo "  ✗ ${name}：缺少 ${env_file}（先运行 ./deploy-infra.sh init-env）" >&2
        return 1
    fi

    local missing
    mapfile -t missing < <(find_placeholder_vars "$env_file")
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "  ✗ ${name}：以下变量仍为占位符/空值：${missing[*]}" >&2
        return 1
    fi
    echo "  ✓ ${name}"
    return 0
}

# 校验一组 stack，任一失败则整体 fail fast。
validate_stacks() {
    local ok=1 stack dir
    echo "=== 校验各 stack 配置 ==="
    for stack in "$@"; do
        dir="${STACKS[$stack]:-}"
        if [[ -z "$dir" ]]; then
            echo "未知 stack：$stack" >&2
            exit 1
        fi
        validate_stack_env "$dir" || ok=0
    done
    if [[ "$ok" -ne 1 ]]; then
        echo "配置校验失败：请补全上述变量（或先运行 ./deploy-infra.sh init-env）。" >&2
        exit 1
    fi
}

resolve_stacks() {
    if [[ "$#" -gt 0 ]]; then
        printf '%s\n' "$@"
        return
    fi
    printf '%s\n' db monitor etcd rabbitmq minio proxy
}

stack_up() {
    local stack="$1"
    local dir="${STACKS[$stack]:-}"

    if [[ -z "$dir" ]]; then
        echo "未知 stack：$stack" >&2
        exit 1
    fi

    echo "=== 启动 ${stack} ==="
    if [[ "$stack" == "proxy" ]]; then
        "${dir}/scripts/proxy.sh" up
    else
        compose_cmd_fixed "$dir" up -d
    fi
}

stack_down() {
    local stack="$1"
    local dir="${STACKS[$stack]:-}"

    if [[ -z "$dir" ]]; then
        echo "未知 stack：$stack" >&2
        exit 1
    fi

    echo "=== 停止 ${stack} ==="
    if [[ "$stack" == "proxy" ]]; then
        "${dir}/scripts/proxy.sh" down
    else
        compose_cmd_fixed "$dir" down
    fi
}

stack_ps() {
    local stack="$1"
    local dir="${STACKS[$stack]:-}"

    if [[ -z "$dir" ]]; then
        echo "未知 stack：$stack" >&2
        exit 1
    fi

    echo "=== ${stack} ==="
    if [[ "$stack" == "proxy" ]]; then
        "${dir}/scripts/proxy.sh" ps
    else
        compose_cmd_fixed "$dir" ps
    fi
}

stack_logs() {
    local stack="$1"
    local dir="${STACKS[$stack]:-}"

    if [[ -z "$dir" ]]; then
        echo "未知 stack：$stack" >&2
        exit 1
    fi

    if [[ "$stack" == "proxy" ]]; then
        "${dir}/scripts/proxy.sh" logs
    else
        compose_cmd_fixed "$dir" logs -f
    fi
}

cmd_init_env() {
    local stacks stack dir generated=0
    mapfile -t stacks < <(resolve_stacks "$@")
    echo "=== 初始化各 stack 的 .env 文件 ==="
    for stack in "${stacks[@]}"; do
        dir="${STACKS[$stack]:-}"
        if [[ -z "$dir" ]]; then
            echo "未知 stack：$stack" >&2
            exit 1
        fi
        [[ -f "$(stack_env_file "$dir")" ]] || generated=1
        ensure_env_from_example "$dir" || true
    done
    if [[ "$generated" -eq 1 ]]; then
        echo
        echo "下一步：编辑上面新生成的 .env.* 文件，把 ${PLACEHOLDER_PREFIX} 占位值改为真实值，再运行 ./deploy-infra.sh up"
    fi
}

cmd_validate() {
    local stacks
    mapfile -t stacks < <(resolve_stacks "$@")
    validate_stacks "${stacks[@]}"
    echo "配置校验通过。"
}

cmd_up() {
    require_docker
    local stacks
    mapfile -t stacks < <(resolve_stacks "$@")
    validate_stacks "${stacks[@]}"
    cmd_init_networks
    for stack in "${stacks[@]}"; do
        stack_up "$stack"
    done
}

cmd_down() {
    require_docker
    local stacks ordered=()
    mapfile -t stacks < <(resolve_stacks "$@")
    # 先停 proxy，再停其余
    for stack in proxy minio rabbitmq etcd monitor db; do
        for s in "${stacks[@]}"; do
            [[ "$s" == "$stack" ]] && ordered+=("$stack")
        done
    done
    for stack in "${ordered[@]}"; do
        stack_down "$stack"
    done
}

cmd_restart() {
    require_docker
    local stacks
    mapfile -t stacks < <(resolve_stacks "$@")
    for stack in "${stacks[@]}"; do
        stack_down "$stack"
        stack_up "$stack"
    done
}

cmd_ps() {
    require_docker
    local stacks
    mapfile -t stacks < <(resolve_stacks "$@")
    for stack in "${stacks[@]}"; do
        stack_ps "$stack"
        echo
    done
}

cmd_logs() {
    require_docker
    local stack="${1:-}"
    if [[ -z "$stack" ]]; then
        echo "用法：$0 logs <stack>" >&2
        exit 1
    fi
    stack_logs "$stack"
}

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init-env) cmd_init_env "$@" ;;
        init-data) cmd_init_data ;;
        init-networks) cmd_init_networks ;;
        init) cmd_init ;;
        validate) cmd_validate "$@" ;;
        up) cmd_up "$@" ;;
        down) cmd_down "$@" ;;
        restart) cmd_restart "$@" ;;
        ps|status) cmd_ps "$@" ;;
        logs) cmd_logs "$@" ;;
        help|-h|--help) usage ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

# 仅在直接执行时运行 main；被 source（如测试）时只加载函数定义。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
