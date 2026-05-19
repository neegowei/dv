# Shared Proxy Services

独立的 nginx + certbot 反向代理栈，用于把多个项目接入同一台服务器的 80/443，并统一管理 Let's Encrypt 证书。

## 架构说明

原项目的 `docker-compose.yaml` 常把 nginx/certbot 与业务放在同一 compose 里，依赖项目内的 nginx 配置、named volumes 和 internal network，适合单项目部署。多个项目各自维护证书和 80/443 时容易重复劳动。

本目录把 proxy 抽成独立 compose project：业务容器只跑应用，proxy 只负责公网入口和 SSL。推荐各项目加入统一 external network（默认 `shared_proxy`），并为被代理服务配置**唯一** network alias（例如 `myapp_web`），避免多个项目都叫 `web` 时冲突。若业务只监听宿主机端口，可将 upstream 设为 `host.docker.internal:端口`。

## 文件说明

| 路径 | 说明 |
|------|------|
| `.env.proxy` | compose、端口、域名、证书、upstream、volume 等变量 |
| `docker-compose.proxy.yaml` | 仅包含 `nginx` 与 `certbot` |
| `nginx.conf` | 全局 nginx 配置 |
| `templates/` | 可复用 nginx 模板 |
| `templates-enabled/` | 当前启用的模板（`up` 会重置为 HTTP 阶段模板） |
| `scripts/proxy.sh` | 启动、签证、扩展、续期、reload、测试等 |
| `examples/p260507-network.override.yaml` | 项目接入共享 proxy network 的 compose override 示例 |

## 前置条件

以下操作默认已满足（本文不再逐步说明 DNS 配置）：

- 域名 A/AAAA 记录已指向当前服务器
- 公网可访问本机 **80** 端口（Let's Encrypt webroot 验证）
- `.env.proxy` 中已设置有效的 `CERTBOT_EMAIL`（不能仍为 `admin@example.com`）

## 证书策略

先选定策略，再按对应流程操作。默认模板面向 `DOMAIN_WWW`（前台）与 `DOMAIN_HT`（后台）两个站点；更多站点需在 `templates/` 增加 server 块并复制到 `templates-enabled/`。

| 策略 | 适用场景 | 首次签发 | 新增子域名 | 续期 |
|------|----------|----------|------------|------|
| **一证多域** | 多个子域放在同一张证书里 | `issue` | `expand` | `renew` |
| **一域一证** | 各子域独立管理、互不影响 | `issue-domain` | 再执行 `issue-domain <新域名>` | `renew`（续 volume 内全部证书） |

## `proxy.sh` 命令一览

```bash
./scripts/proxy.sh up              # 创建 network，启用 HTTP 模板，启动 nginx
./scripts/proxy.sh issue           # 按 CERTBOT_DOMAINS 申请证书，切换 HTTPS 并 reload
./scripts/proxy.sh issue-domain <domain>  # 为单个域名单独申请证书（不切换 HTTPS）
./scripts/proxy.sh expand          # 按 CERTBOT_DOMAINS 扩展已有证书并 reload
./scripts/proxy.sh renew           # 续期全部证书并 reload
./scripts/proxy.sh reload          # 重新渲染 templates-enabled 并 reload
./scripts/proxy.sh test            # 渲染模板并执行 nginx -t
./scripts/proxy.sh ps              # 查看服务状态
./scripts/proxy.sh logs            # 跟踪日志
./scripts/proxy.sh down            # 停止 proxy 容器
```

可选环境变量：`PROXY_ENV_FILE=/path/to/.env.proxy ./scripts/proxy.sh <cmd>`

## 首次上线

### 1. 编辑 `.env.proxy`

```bash
CERTBOT_EMAIL=you@example.com
CERTBOT_DOMAINS=www.example.com admin.example.com
CERT_NAME=www.example.com

DOMAIN_WWW=www.example.com
DOMAIN_HT=admin.example.com
DOMAIN_WWW_CERT_NAME=www.example.com    # 一证多域时与 CERT_NAME 相同
DOMAIN_HT_CERT_NAME=www.example.com

WEB_UPSTREAM=myapp_web:80               # 或 host.docker.internal:7270
ADMIN_UPSTREAM=myapp_admin:8080
```

### 2. 业务容器接入 proxy 网络（若使用 Docker 内网 upstream）

在项目目录使用 override 示例，将 web / admin 等服务挂到 `shared_proxy` 并设置唯一 alias：

```bash
cd /path/to/project
docker compose -f docker-compose.yaml \
  -f /path/to/scripts/proxy/examples/p260507-network.override.yaml \
  up -d --build
```

### 3. 启动 proxy（HTTP 阶段）

```bash
cd /path/to/scripts/proxy
./scripts/proxy.sh up
```

`up` 会创建 Docker network、将 `templates-enabled/` 设为 HTTP 反代（含 `/.well-known/acme-challenge/`），并启动 nginx。

### 4. 申请证书

**方式 A：一证多域（推荐首次就确定完整域名列表）**

```bash
./scripts/proxy.sh issue
```

签发成功后自动切换 HTTPS 模板并 reload。证书目录：`/etc/letsencrypt/live/<CERT_NAME>/`（持久化在 `LETSENCRYPT_VOLUME`）。

**方式 B：一域一证**

```bash
./scripts/proxy.sh issue-domain www.example.com
./scripts/proxy.sh issue-domain admin.example.com
```

在 `.env.proxy` 中为各 server 指定证书名：

```bash
DOMAIN_WWW_CERT_NAME=www.example.com
DOMAIN_HT_CERT_NAME=admin.example.com
```

将 HTTPS 模板放入 `templates-enabled/`（可从 `templates/20-https.conf.template` 复制），然后：

```bash
./scripts/proxy.sh reload
```

`issue-domain` 不会自动切换 HTTPS，避免只签部分域名时 nginx 因缺证书无法 reload。

## 已有站点：新增子域名

**不要**把 `./scripts/proxy.sh up` 当作日常更新命令。`up` 会重置 `templates-enabled/` 为首次 HTTP 模板（不删除已有证书，但会覆盖你已改的 HTTPS 配置）。

### 路径 1：一证多域（曾使用 `issue`）

1. 在 `.env.proxy` 中将 **旧域名 + 新域名** 完整写入 `CERTBOT_DOMAINS`，`CERT_NAME` 保持不变：

   ```bash
   CERTBOT_DOMAINS=www.example.com admin.example.com new.example.com
   CERT_NAME=www.example.com
   ```

2. 按需修改 `DOMAIN_*`、`*_UPSTREAM` 及 nginx 模板（`templates/` → 复制到 `templates-enabled/`）。

3. 测试并重载：

   ```bash
   ./scripts/proxy.sh test
   ./scripts/proxy.sh reload
   ```

4. 扩展证书：

   ```bash
   ./scripts/proxy.sh expand
   ```

> **注意**：`expand` 只填新域名会导致证书 SAN 仅保留新列表中的域名。必须传入 **完整** 域名列表。

### 路径 2：一域一证（曾使用 `issue-domain`）

1. 确保新域名在 HTTP 模板中可响应 `/.well-known/acme-challenge/`（已有 HTTP 或 redirect 模板即可）。

2. 签发新域证书：

   ```bash
   ./scripts/proxy.sh issue-domain new.example.com
   ```

3. 增加 nginx server 配置，设置 `DOMAIN_*_CERT_NAME=new.example.com`。

4. `./scripts/proxy.sh reload`

一般 **不需要** `expand`，除非要把多个域名合并回同一张证书。

## 证书续期

```bash
./scripts/proxy.sh renew
```

对 volume 内所有 Let's Encrypt 证书执行 `certbot renew`，成功后 reload nginx。建议用 cron 或 systemd timer 定期执行（例如每月两次）；certbot 仅在临近过期时才会真正续签。

续期**不需要**修改 `CERTBOT_DOMAINS`。`expand` 仅用于向已有证书增加 SAN（新子域），不是日常续期操作。

## 日常运维

| 场景 | 命令 |
|------|------|
| 修改 upstream、端口或 `.env.proxy` 变量 | `test` → `reload` |
| 修改 `templates-enabled/` 中的 nginx 配置 | `test` → `reload` |
| 查看运行状态 | `ps` |
| 排查问题 | `logs` |
| 停止 proxy | `down` |

## 新项目接入（不涉及新域名）

1. 在新项目 compose 中加入 external network `${PROXY_NETWORK:-shared_proxy}`。
2. 为被代理服务设置唯一 alias（例如 `myapp_web`）。
3. 在 `.env.proxy` 中新增或修改 upstream 变量。
4. 在 `templates/` 增加 server 模板，复制到 `templates-enabled/`。
5. `./scripts/proxy.sh reload`

若新接入的是**新公网域名**，还需按上文「新增子域名」流程更新证书。

## 直接使用 docker compose

脚本内部调用同一 compose 文件；需要手动执行时：

```bash
cd /path/to/scripts/proxy
docker network create shared_proxy
docker compose --env-file .env.proxy -f docker-compose.proxy.yaml up -d nginx
```

## 宿主机端口 upstream

业务只监听本机端口时：

```bash
WEB_UPSTREAM=host.docker.internal:7270
ADMIN_UPSTREAM=host.docker.internal:8090
```

## 常见问题

- **`up` 与 `reload`**：日常改配置用 `reload`；仅首次部署或刻意回到 HTTP 签证前状态时用 `up`。
- **80 端口**：webroot 验证要求公网能访问 `http://<域名>/.well-known/acme-challenge/`。
- **`CERTBOT_STAGING=1`**：使用 Let's Encrypt 测试环境，调试完成后改回 `0`。
- **证书路径**：容器内为 `/etc/letsencrypt/live/<cert-name>/`，数据保存在 `LETSENCRYPT_VOLUME` 命名卷中。
