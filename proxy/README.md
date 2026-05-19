# Shared Proxy Services

独立的 nginx + certbot 反向代理栈，用于把多个项目接入同一台服务器的 80/443，并统一管理 Let's Encrypt 证书。

本仓库中 proxy 与 `deploy-infra.sh` 配合，为 db / monitor / minio 等基础设施提供统一公网入口。

## 架构说明

原项目的 `docker-compose.yaml` 常把 nginx/certbot 与业务放在同一 compose 里，依赖项目内的 nginx 配置、named volumes 和 internal network，适合单项目部署。多个项目各自维护证书和 80/443 时容易重复劳动。

本目录把 proxy 抽成独立 compose project：业务容器只跑应用，proxy 只负责公网入口和 SSL。推荐各项目加入统一 external network（默认 `shared_proxy`），并为被代理服务配置**唯一** network alias（例如 `p260507_web`），避免多个项目都叫 `web` 时冲突。若业务只监听宿主机端口，可将 upstream 设为 `host.docker.internal:端口`。

证书与 ACME webroot 数据挂载在宿主机 `${DATA_ROOT:-/data}/certbot-www` 与 `${DATA_ROOT:-/data}/letsencrypt`（由 `deploy-infra.sh init-data` 创建目录）。

## 文件说明

| 路径 | 说明 |
|------|------|
| `.env.proxy` | compose、端口、域名、证书、upstream 等变量 |
| `docker-compose.yaml` | 仅包含 `nginx` 与 `certbot` |
| `nginx.conf` | 全局 nginx 配置 |
| `templates/` | 可复用 nginx 模板（`up` / `issue` 会从这里复制到 `templates-enabled/`） |
| `templates-enabled/` | 当前启用的模板（日常改配置应直接编辑此处，再用 `reload`） |
| `scripts/proxy.sh` | 启动、签证、扩展、续期、reload、测试等 |
| `scripts/lib-proxy.sh` | 公共函数（compose、模板渲染、network） |
| `tests/proxy_issue_domain_test.sh` | `issue-domain` 行为回归测试（无需真实 Docker） |
| `examples/p260507-network.override.yaml` | 项目接入 `shared_proxy` 的 compose override 示例 |

## 前置条件

以下操作默认已满足（本文不再逐步说明 DNS 配置）：

- 域名 A/AAAA 记录已指向当前服务器
- 公网可访问本机 **80** 端口（Let's Encrypt webroot 验证）
- `.env.proxy` 中已设置有效的 `CERTBOT_EMAIL`（不能仍为 `admin@example.com`）
- 宿主机已存在 `/data/certbot-www` 与 `/data/letsencrypt`（或先执行仓库根目录 `sudo ./deploy-infra.sh init-data`）

## 证书策略

先选定策略，再按对应流程操作。默认模板面向两个站点（`DOMAIN_WWW` 前台、`DOMAIN_HT` 后台）；更多站点需在 `templates/` 增加 server / upstream 块，同步扩展 `lib-proxy.sh` 中 `envsubst` 的变量列表，再复制到 `templates-enabled/`。

| 策略 | 适用场景 | 首次签发 | 新增子域名 | 续期 |
|------|----------|----------|------------|------|
| **一证多域** | 多个子域放在同一张证书里 | `issue` | `expand` | `renew` |
| **一域一证** | 各子域独立管理、互不影响 | `issue-domain <域名>` | 再执行 `issue-domain <新域名>` | `renew`（续 volume 内全部证书） |

## `proxy.sh` 命令一览

```bash
cd proxy
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
./scripts/proxy.sh help            # 打印用法
```

可选环境变量：

| 变量 | 说明 |
|------|------|
| `PROXY_ENV_FILE` | 覆盖默认 `.env.proxy` 路径 |
| `PROXY_COMPOSE_FILE` | 覆盖默认 `docker-compose.yaml` 路径 |

示例：

```bash
PROXY_ENV_FILE=/path/to/.env.proxy ./scripts/proxy.sh reload
```

## 环境变量（`.env.proxy`）

### Compose 与网络

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROXY_PROJECT_NAME` | `shared-proxy` | compose project 名 |
| `PROXY_NETWORK` | `shared_proxy` | external network 名 |
| `NGINX_IMAGE` / `CERTBOT_IMAGE` | 见文件 | 镜像 |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | 宿主机映射端口 |

### 默认模板变量（双站点示例）

`render_templates_in_nginx` 仅替换下列占位符，修改模板时请保持一致：

| 变量 | 说明 |
|------|------|
| `DOMAIN_WWW` / `DOMAIN_HT` | 两个 `server_name` |
| `DOMAIN_WWW_CERT_NAME` / `DOMAIN_HT_CERT_NAME` | HTTPS 证书目录名（`/etc/letsencrypt/live/<name>/`） |
| `WEB_UPSTREAM` / `ADMIN_UPSTREAM` | upstream 地址（`host:port` 或 Docker alias） |
| `CERT_NAME` | 一证多域时的证书名（`issue` / `expand`） |
| `CERTBOT_DOMAINS` | 空格或逗号分隔的 SAN 列表；为空时回退为 `DOMAIN_WWW` + `DOMAIN_HT` |
| `CERTBOT_EMAIL` | Let's Encrypt 联系邮箱（必填） |
| `CERTBOT_STAGING` | `1` 使用测试 CA |

### 本仓库基础设施示例（可扩展）

当前 `.env.proxy` 还预留了 monitor / store 等域名与 upstream，供自定义模板使用（**不会**被默认 `templates/` 自动消费）：

```bash
DOMAIN_MONITOR=monitor.example.com
DOMAIN_STORE=store.example.com
DOMAIN_ADMIN_STORE=admin.store.example.com
DOMAIN_MONITOR_CERT_NAME=monitor.example.com
# ...

GRAFANA_UPSTREAM=grafana:3000
MINIO_API_UPSTREAM=minio:9000
MINIO_CONSOLE_UPSTREAM=minio:9001
```

接入 Grafana / MinIO 时，除在对应 stack 的 compose 中加入 `shared_proxy` 网络外，还需在 `templates/` 编写 server 块并在 `lib-proxy.sh` 的 `envsubst` 列表中加入上述变量名。

## 与 `deploy-infra.sh` 集成

仓库根目录脚本可统一管理 proxy 与其它 stack：

```bash
# 初始化 /data 子目录与 Docker networks（含 shared_proxy）
sudo ./deploy-infra.sh init

# 仅启动 proxy（内部调用 proxy/scripts/proxy.sh up）
./deploy-infra.sh up proxy

./deploy-infra.sh ps proxy
./deploy-infra.sh logs proxy
./deploy-infra.sh down proxy
```

证书签发、扩展、续期仍须在 `proxy/` 目录下手动执行 `proxy.sh issue` / `issue-domain` / `expand` / `renew`（尚未封装进 `deploy-infra.sh`）。

## 首次上线

### 1. 编辑 `.env.proxy`

双站点 + 一证多域示例：

```bash
CERTBOT_EMAIL=you@example.com
CERTBOT_DOMAINS=www.example.com admin.example.com
CERT_NAME=www.example.com

DOMAIN_WWW=www.example.com
DOMAIN_HT=admin.example.com
DOMAIN_WWW_CERT_NAME=www.example.com
DOMAIN_HT_CERT_NAME=www.example.com

WEB_UPSTREAM=myapp_web:80               # 或 host.docker.internal:7270
ADMIN_UPSTREAM=myapp_admin:8080
```

### 2. 业务容器接入 proxy 网络（若使用 Docker 内网 upstream）

在项目目录使用 override 示例，将服务挂到 `shared_proxy` 并设置唯一 alias：

```bash
cd /path/to/project
docker compose -f docker-compose.yaml \
  -f /path/to/dv/proxy/examples/p260507-network.override.yaml \
  up -d --build
```

### 3. 启动 proxy（HTTP 阶段）

```bash
cd /path/to/dv/proxy
./scripts/proxy.sh up
```

`up` 会创建 Docker network、将 `templates-enabled/` **重置**为 HTTP 反代模板（含 `/.well-known/acme-challenge/`），并启动 nginx。

### 4. 申请证书

**方式 A：一证多域（推荐首次就确定完整域名列表）**

```bash
./scripts/proxy.sh issue
```

签发成功后自动切换 HTTPS 模板并 reload。证书路径：`/etc/letsencrypt/live/<CERT_NAME>/`（宿主机 `${DATA_ROOT:-/data}/letsencrypt/live/<CERT_NAME>/`）。

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

将 HTTPS 模板放入 `templates-enabled/`（`issue` 会自动复制；一域一证时可从 `templates/20-https.conf.template` 手动复制），然后：

```bash
./scripts/proxy.sh reload
```

`issue-domain` **不会**自动切换 HTTPS，避免只签部分域名时 nginx 因缺证书无法 reload。证书名与域名相同（`--cert-name <domain>`），且**不会**读取 `CERTBOT_DOMAINS`。

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

3. 增加 nginx server 配置，设置 `DOMAIN_*_CERT_NAME=new.example.com`（或对应自定义变量）。

4. `./scripts/proxy.sh reload`

一般 **不需要** `expand`，除非要把多个域名合并回同一张证书。

## 证书续期

```bash
./scripts/proxy.sh renew
```

对 `/data/letsencrypt` 内所有 Let's Encrypt 证书执行 `certbot renew`，成功后 reload nginx。建议用 cron 或 systemd timer 定期执行（例如每月两次）；certbot 仅在临近过期时才会真正续签。

续期**不需要**修改 `CERTBOT_DOMAINS`。`expand` 仅用于向已有证书增加 SAN（新子域），不是日常续期操作。

## 日常运维

| 场景 | 命令 |
|------|------|
| 修改 upstream、端口或 `.env.proxy` 变量 | `test` → `reload` |
| 修改 `templates-enabled/` 中的 nginx 配置 | `test` → `reload` |
| 查看运行状态 | `ps` 或 `deploy-infra.sh ps proxy` |
| 排查问题 | `logs` |
| 停止 proxy | `down` |

## 新项目接入（不涉及新域名）

1. 在新项目 compose 中加入 external network `${PROXY_NETWORK:-shared_proxy}`。
2. 为被代理服务设置唯一 alias（例如 `myapp_web`）。
3. 在 `.env.proxy` 中新增或修改 upstream / 域名变量。
4. 在 `templates/` 增加 server 模板，复制到 `templates-enabled/`（必要时扩展 `envsubst` 变量列表）。
5. `./scripts/proxy.sh reload`

若新接入的是**新公网域名**，还需按上文「新增子域名」流程更新证书。

## 直接使用 docker compose

脚本内部调用同一 compose 文件；需要手动执行时：

```bash
cd proxy
docker network create shared_proxy 2>/dev/null || true
docker compose --env-file .env.proxy -f docker-compose.yaml up -d nginx
```

## 宿主机端口 upstream

业务只监听本机端口时：

```bash
WEB_UPSTREAM=host.docker.internal:7270
ADMIN_UPSTREAM=host.docker.internal:8090
```

`docker-compose.yaml` 已为 nginx 配置 `host.docker.internal:host-gateway`。

## 测试

```bash
cd proxy
./tests/proxy_issue_domain_test.sh
```

验证 `issue-domain` 使用传入域名作为 `--cert-name` 与唯一 `-d`，且不会误用 `CERTBOT_DOMAINS`。

## 常见问题

- **`up` 与 `reload`**：日常改配置用 `reload`；仅首次部署或刻意回到 HTTP 签证前状态时用 `up`。
- **80 端口**：webroot 验证要求公网能访问 `http://<域名>/.well-known/acme-challenge/`。
- **`CERTBOT_STAGING=1`**：使用 Let's Encrypt 测试环境，调试完成后改回 `0`。
- **证书路径**：容器内为 `/etc/letsencrypt/live/<cert-name>/`，宿主机为 `/data/letsencrypt/live/<cert-name>/`（与 `DATA_ROOT` 一致时）。
- **模板变量未生效**：检查占位符是否在 `lib-proxy.sh` 的 `envsubst` 列表中，且已执行 `reload` 或 `test`。
