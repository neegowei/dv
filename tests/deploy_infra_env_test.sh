#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# source 脚本以直接测试内部函数；脚本带 source guard，source 时不执行 main。
# shellcheck source=../deploy-infra.sh
source "$ROOT/deploy-infra.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# --- find_placeholder_vars：空值与 CHANGE_ME 占位应被检出，真实值/带默认值的不应 ---
test_find_placeholder_vars_detects_empty_and_change_me() {
    local env_file="$TMP_DIR/sample.env"
    cat >"$env_file" <<'ENV'
# 注释行应忽略
PROJECT_NAME=shared-db
MYSQL_ROOT_PASSWORD=CHANGE_ME
MYSQL_USER=admin
REDIS_PASS=CHANGE_ME
MINIO_ROOT_PASSWORD=CHANGE_ME_MIN_8_CHARS
EMPTY_VALUE=
REAL_SECRET=s3cr3t-value
PORT=5672
ENV

    local out
    out="$(find_placeholder_vars "$env_file")"

    grep -qx "MYSQL_ROOT_PASSWORD" <<<"$out" || fail "应检出 MYSQL_ROOT_PASSWORD"
    grep -qx "REDIS_PASS" <<<"$out" || fail "应检出 REDIS_PASS"
    grep -qx "MINIO_ROOT_PASSWORD" <<<"$out" || fail "应检出 MINIO_ROOT_PASSWORD（CHANGE_ME 前缀）"
    grep -qx "EMPTY_VALUE" <<<"$out" || fail "应检出空值 EMPTY_VALUE"
    if grep -qx "REAL_SECRET" <<<"$out"; then fail "不应检出已填真实值 REAL_SECRET"; fi
    if grep -qx "PROJECT_NAME" <<<"$out"; then fail "不应检出正常默认值 PROJECT_NAME"; fi
    if grep -qx "PORT" <<<"$out"; then fail "不应检出端口默认值 PORT"; fi
}

# --- ensure_env_from_example：缺 .env 时从 example 生成，且幂等不覆盖 ---
test_ensure_env_from_example_generates_then_is_idempotent() {
    local dir="$TMP_DIR/svc"
    mkdir -p "$dir"
    printf 'KEY=value-from-example\n' >"$dir/.env.svc.example"

    ensure_env_from_example "$dir" >/dev/null
    [[ -f "$dir/.env.svc" ]] || fail "应从 example 生成 .env.svc"
    grep -qx "KEY=value-from-example" "$dir/.env.svc" || fail ".env.svc 内容应来自 example"

    # 用户改过真实值后再次调用，不能覆盖
    printf 'KEY=user-real-value\n' >"$dir/.env.svc"
    ensure_env_from_example "$dir" >/dev/null
    grep -qx "KEY=user-real-value" "$dir/.env.svc" || fail "已存在的 .env.svc 不应被覆盖"
}

# --- ensure_env_from_example：缺 example 时报错（返回非零） ---
test_ensure_env_from_example_missing_example_fails() {
    local dir="$TMP_DIR/noex"
    mkdir -p "$dir"

    set +e
    ensure_env_from_example "$dir" >/dev/null 2>&1
    local status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "缺少 example 时应返回非零"
}

# --- validate_stack_env：占位/空值 → 失败；填好 → 通过；缺文件 → 失败 ---
test_validate_stack_env() {
    local dir="$TMP_DIR/vsvc"
    mkdir -p "$dir"

    # 缺 .env
    set +e
    validate_stack_env "$dir" >/dev/null 2>&1; local s_missing=$?
    set -e
    [[ "$s_missing" -ne 0 ]] || fail "缺少 .env 时应失败"

    # 含占位符
    printf 'TOKEN=CHANGE_ME\n' >"$dir/.env.vsvc"
    set +e
    validate_stack_env "$dir" >/dev/null 2>&1; local s_placeholder=$?
    set -e
    [[ "$s_placeholder" -ne 0 ]] || fail "含 CHANGE_ME 占位符时应失败"

    # 全部填好
    printf 'TOKEN=real-token\n' >"$dir/.env.vsvc"
    set +e
    validate_stack_env "$dir" >/dev/null 2>&1; local s_ok=$?
    set -e
    [[ "$s_ok" -eq 0 ]] || fail "填好真实值后应通过"
}

# --- validate 应对齐 example 的必填项（CHANGE_ME）：必填缺失 → 失败；可选缺失 → 通过 ---
test_validate_detects_missing_required_var() {
    local dir="$TMP_DIR/msvc"
    mkdir -p "$dir"
    # example：SECRET 为必填（CHANGE_ME），PORT 为可选（有默认值）
    printf 'SECRET=CHANGE_ME\nPORT=8080\n' >"$dir/.env.msvc.example"

    # .env 缺失必填 SECRET（整行没有），仅有可选 PORT → 应失败
    printf 'PORT=8080\n' >"$dir/.env.msvc"
    set +e
    validate_stack_env "$dir" >/dev/null 2>&1; local s_missing=$?
    set -e
    [[ "$s_missing" -ne 0 ]] || fail "必填变量 SECRET 整行缺失时应失败"

    # .env 含 SECRET 真实值、缺可选 PORT（有默认值）→ 应通过
    printf 'SECRET=real-secret\n' >"$dir/.env.msvc"
    set +e
    validate_stack_env "$dir" >/dev/null 2>&1; local s_ok=$?
    set -e
    [[ "$s_ok" -eq 0 ]] || fail "仅可选变量 PORT 缺失（有默认值）不应失败"
}

test_find_placeholder_vars_detects_empty_and_change_me
test_ensure_env_from_example_generates_then_is_idempotent
test_ensure_env_from_example_missing_example_fails
test_validate_stack_env
test_validate_detects_missing_required_var

echo "✅ deploy_infra_env_test 全部通过"
