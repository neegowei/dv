# Shared Proxy Services

独立的 nginx + certbot 反向代理栈，用于把多个项目接入同一台服务器的 80/443，并统一管理 Let's Encrypt 证书。

本仓库中 proxy 与仓库根目录 [`deploy-infra.sh`](../deploy-infra.sh) 配合，为 db / monitor / minio 等基础设施提供统一公网入口。

> **公开仓库**：`.env.proxy`、`conf.d-enabled/*.conf`、`templates-enabled/` 已加入根目录 `.gitignore`，仅保存在服务器。仓库内只提交 `templates/` 下的通用 infra 模板与 `examples/` 下的接入示例。

## 架构说明

原项目的 `docker-compose.yaml` 常把 nginx/certbot 与业务放在同一 compose 里，依赖项目内的 nginx 配置、named volumes 和 internal network，适合单项目部署。多个项目各自维护证书和 80/443 时容易重复劳动。

本目录把 proxy 抽成独立 compose project：业务容器只跑应用，proxy 只负责公网入口和 SSL。推荐各项目加入统一 external network（默认 `shared_proxy`），并为被代理服务配置**唯一** network alias（例如 `p260507_web`），避免多个项目都叫 `web` 时冲突。若业务只监听宿主机端口，可将 upstream 设为 `host.docker.internal:端口`。

证书与 ACME webroot 数据挂载在宿主机 `${DATA_ROOT:-/data}/certbot-www` 与 `${DATA_ROOT:-/data}/letsencrypt`（由 `deploy-infra.sh init-data` 创建目录）。

### 配置如何生效

```
templates/              # 仓库内可版本化的 infra 模板（${DOMAIN_*} 占位符）
    ↓  proxy.sh up / enable-https 复制；自定义站点手动追加
templates-enabled/      # 当前启用的模板（gitignore，在服务器维护）
    ↓  proxy.sh reload / test（宿主机 envsubst，读取 .env.proxy）
conf.d-enabled/         # 渲染后的 nginx 配置（gitignore）
    ↓  docker-compose 挂载
容器 /etc/nginx/conf.d/
```

- 模板在**宿主机**用 `envsubst` 渲染（需安装 `gettext` 包），避免在 `docker compose exec` 里展开 glob 等问题。
- 渲染时自动扫描 `templates-enabled/*.template` 内的 `${VAR}` 占位符；nginx 自身的 `$host`、`$scheme`、`$request_uri` 等裸变量不会被替换。
- **不要**把模板挂到镜像自带的 `/etc/nginx/templates`（官方 entrypoint 会占用该路径）。

## 文件说明

| 路径 | 进 Git | 说明 |
|------|--------|------|
| `.env.proxy` | 否 | compose、域名、证书、upstream（在服务器创建） |
| `docker-compose.yaml` | 是 | nginx + certbot；`conf.d-enabled` 挂载为 `conf.d` |
| `nginx.conf` | 是 | 全局 nginx 配置 |
| `templates/` | 是 | 默认 infra 模板源文件 |
| `templates-enabled/` | 否 | 当前启用的 `.template` 副本 |
| `conf.d-enabled/` | 否（仅 `.gitkeep`） | 渲染产物 `*.conf` |
| `scripts/proxy.sh` | 是 | 启动、签证、HTTPS、reload 等 |
| `scripts/lib-proxy.sh` | 是 | compose、模板复制、宿主机渲染 |
| `tests/proxy_issue_domain_test.sh` | 是 | `issue-domain` 行为回归测试 |
| `tests/proxy_template_behavior_test.sh` | 是 | 模板渲染与 `issue` / `up` 行为回归测试 |
| `examples/p260507-network.override.yaml` | 是 | 项目接入 `shared_proxy` 的示例 |
| `examples/frontend-backend/templates/` | 是 | 旧前端/后端双站点模板示例 |

## 前置条件

以下操作默认已满足（本文不再逐步说明 DNS 配置）：

- 域名 A/AAAA 记录已指向当前服务器
- 公网可访问本机 **80** 端口（Let's Encrypt webroot 验证）
- `.env.proxy` 中 `CERTBOT_EMAIL` 已换成**真实可收信邮箱**（不能保留示例值如 `admin@example.test`；注意脚本目前只硬拒 `admin@example.com`，示例的 `.test` 邮箱不会被拦，但你将收不到 Let's Encrypt 的到期通知）
- 宿主机已存在 `/data/certbot-www` 与 `/data/letsencrypt`（或先执行 `sudo ./deploy-infra.sh init-data`）
- 宿主机已安装 `envsubst`（Debian/Ubuntu：`gettext` 包）

## 证书策略

| 策略 | 适用场景 | 首次签发 | 启用 HTTPS 反代 | 新增子域名 | 续期 |
|------|----------|----------|-----------------|------------|------|
| **一证多域** | 多个子域在同一张证书 | `issue` | 追加 HTTPS 模板 + `reload` | 更新模板 + `expand` | `renew` |
| **一域一证** | 各子域独立证书 | `issue-domain <域名>` | `enable-https` 或手动模板 + `reload` | 再 `issue-domain` | `renew` |

默认 `templates/` 只保留基础设施三域名模板。旧前端/后端双站点模板已迁到 `examples/frontend-backend/templates/`，需要时复制到 `templates-enabled/` 后再 `reload`。

## `proxy.sh` 命令一览

```bash
cd proxy
./scripts/proxy.sh up              # 创建 network，必要时初始化 HTTP 模板，渲染配置并启动 nginx
./scripts/proxy.sh issue           # 按 CERTBOT_DOMAINS 申请证书，并 reload 当前启用模板
./scripts/proxy.sh issue-domain <domain>
                                   # 单域名证书；不切换 HTTPS 模板
./scripts/proxy.sh enable-https    # 基础设施三域名：启用 infra HTTPS 模板并 reload
./scripts/proxy.sh expand          # 按 CERTBOT_DOMAINS 扩展已有证书并 reload
./scripts/proxy.sh renew           # 续期全部证书并 reload
./scripts/proxy.sh reload          # 宿主机渲染 templates-enabled → conf.d-enabled 并 reload
./scripts/proxy.sh test            # 渲染并 nginx -t
./scripts/proxy.sh ps
./scripts/proxy.sh logs
./scripts/proxy.sh down
./scripts/proxy.sh help
```

可选环境变量：

| 变量 | 说明 |
|------|------|
| `PROXY_ENV_FILE` | 覆盖默认 `.env.proxy` 路径 |
| `PROXY_COMPOSE_FILE` | 覆盖默认 `docker-compose.yaml` 路径 |

## 环境变量（`.env.proxy`）

在服务器新建并编辑（勿提交 Git），字段见下表。

### Compose 与网络

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROXY_PROJECT_NAME` | `shared-proxy` | compose project 名 |
| `PROXY_NETWORK` | `shared_proxy` | external network 名 |
| `NGINX_IMAGE` / `CERTBOT_IMAGE` | 见文件 | 镜像 |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | 宿主机映射端口 |

### 证书变量

| 变量 | 说明 |
|------|------|
| `CERTBOT_DOMAINS` | SAN 列表，推荐逗号分隔；空格分隔时需加引号；`issue` / `expand` 必填 |
| `CERT_NAME` | 一证多域时的证书名；为空时使用 `CERTBOT_DOMAINS` 的第一个域名 |
| `CERTBOT_EMAIL` | Let's Encrypt 邮箱（必填） |
| `CERTBOT_STAGING` | `1` 使用测试 CA |

### 基础设施模板（`enable-https`）

| 变量 | 说明 |
|------|------|
| `DOMAIN_MONITOR` / `DOMAIN_STORE` / `DOMAIN_ADMIN_STORE` | 三个 `server_name` |
| `DOMAIN_*_CERT_NAME` | 与 `issue-domain` 的 `--cert-name` 一致，通常同域名 |
| `GRAFANA_UPSTREAM` | 如 `host.docker.internal:3000` 或 `grafana:3000`（需在 `shared_proxy`） |
| `STORE_UPSTREAM` / `ADMIN_STORE_UPSTREAM` | 业务宿主机端口，如 `host.docker.internal:7270` |

自定义模板可使用任意 `${VAR}` 占位符，只要 `.env.proxy` 中提供同名变量即可；无需改脚本。

## 基础设施 HTTPS（一域一证）

适用于 monitor / store / admin.store 等已用 `issue-domain` 分别签证的场景。

### 模板文件（已在 `templates/`）

| 文件 | 作用 |
|------|------|
| `05-infra-upstreams.conf.template` | grafana / store / admin_store upstream |
| `10-http-infra.conf.template` | 仅 HTTP（签证前；`up` 在没有启用模板时复制） |
| `10-http-redirect-infra.conf.template` | HTTP 跳转 HTTPS + ACME |
| `20-https-infra.conf.template` | 443 + 证书路径 + `proxy_pass` |

### 推荐流程

```bash
cd proxy

# 1. 编辑 .env.proxy（域名、upstream、CERTBOT_EMAIL）
# 2. 启动 proxy（HTTP，含 ACME）
./scripts/proxy.sh up
# 或：../deploy-infra.sh up proxy

# 3. 按域名签发（每个域名一次）
./scripts/proxy.sh issue-domain monitor.example.com
./scripts/proxy.sh issue-domain store.example.com
./scripts/proxy.sh issue-domain admin.store.example.com

# 4. 启用 HTTPS 反代（仅 infra 三域名模板）
./scripts/proxy.sh enable-https

# 5. 验证
curl -sI https://monitor.example.com/
```

`enable-https` 会：清空并填充 `templates-enabled/`（infra HTTPS 模板）→ 宿主机 `envsubst` 写入 `conf.d-enabled/` → `nginx -t` → reload。

修改 upstream 或域名后：`./scripts/proxy.sh reload`。`up` 会保留已有 `templates-enabled/`，只在没有启用模板时初始化 infra HTTP 模板，并在启动 nginx 前渲染当前模板。

若后端在宿主机端口，保持 `docker-compose.yaml` 中 `host.docker.internal:host-gateway`；业务未监听时 HTTPS 可达但会 **502**。

## 与 `deploy-infra.sh` 集成

```bash
# 仓库根目录
sudo ./deploy-infra.sh init
./deploy-infra.sh up proxy
./deploy-infra.sh ps proxy
./deploy-infra.sh logs proxy
```

证书签发、`enable-https`、`reload` 仍在 `proxy/` 下手动执行（尚未封装进 `deploy-infra.sh`）。

## 分步示例：新增一个站点（demo）

下面用占位名 `demo` 演示如何接入一个新站点。把命令里的 `<path-to-your-dv>` 换成你本机仓库根目录的绝对路径（例如 `/home/you/dv`），把 `demo` / `demo_web` / 域名换成你自己的。

站点采用「运行时 resolver」写法：upstream 用变量 + `resolver 127.0.0.11`，后端没启动时只让该站点 502，不会拖垮整个 nginx。

- **本地 HTTP**（`*.localhost`，无需证书）→ A
- **公网 HTTPS**（真实域名 + Let's Encrypt 证书）→ B

### A. 本地 HTTP 站点（`demo.localhost` → `demo_web:3000`）

**1. 建站点模板** `<path-to-your-dv>/proxy/templates-enabled/30-http-demo.conf.template`：

```nginx
# edge proxy 站点 —— demo.localhost（本地 HTTP，无需证书）
server {
    listen 80;
    server_name ${DOMAIN_DEMO};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    location / {
        # 按请求解析 demo_web；后端未启动时仅本站 502，不影响 nginx reload
        resolver 127.0.0.11 valid=10s ipv6=off;
        set $demo_upstream ${DEMO_UPSTREAM};
        proxy_pass http://$demo_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

**2. `.env.proxy` 增加变量**：

```bash
DOMAIN_DEMO=demo.localhost
DEMO_UPSTREAM=demo_web:3000
```

**3. 渲染并热重载**（`reload` 要求 nginx 已在运行；首次部署 proxy 时改用 `up`）：

```bash
cd <path-to-your-dv>/proxy
./scripts/proxy.sh reload      # proxy 尚未启动时改用：./scripts/proxy.sh up
```

**4. 后端接入 `shared_proxy`（关键）**：后端容器须在 `shared_proxy` 网络上、network alias 为 `demo_web`（与 `DEMO_UPSTREAM` 对应），否则始终 502。在你的业务 compose 里：

```yaml
networks:
  shared_proxy:
    external: true
services:
  app:                       # 监听 3000
    networks:
      shared_proxy:
        aliases: [demo_web]
```

> `demo.localhost` 在本机自动解析到 `127.0.0.1`；远程访问需在客户端 hosts 指向 proxy 主机。

### B. 公网 HTTPS 站点（`demo.example.com` → `demo_web:3000`）

`*.localhost` 无法签发证书，HTTPS 必须用**真实公网域名**，并满足[前置条件](#前置条件)（DNS 指向本机、80 端口公网可达、`CERTBOT_EMAIL` 有效）。

> **顺序很关键**：证书签发**之前**只能启用 HTTP 模板；HTTPS 模板引用证书文件，必须等签发成功后再加入，否则 `nginx -t` 会因找不到证书而失败。

**1. 建 HTTP 模板**：同 A 的 `30-http-demo.conf.template`，把 `DOMAIN_DEMO` 设为公网域名即可。如需强制跳转 HTTPS，可把 `location /` 内容换成 `return 301 https://$host$request_uri;`，但 `acme-challenge` 那个 location **必须保留**（供签证验证）。

**2. `.env.proxy` 增加变量**：

```bash
CERTBOT_EMAIL=you@example.com         # 必填，换成你的真实可收信邮箱（勿保留示例值）
DOMAIN_DEMO=demo.example.com
DEMO_UPSTREAM=demo_web:3000
DEMO_CERT_NAME=demo.example.com
```

**3. 起 nginx（确保 80 可达）并签发证书**：

```bash
cd <path-to-your-dv>/proxy
./scripts/proxy.sh up                            # 已在运行则改用 reload
./scripts/proxy.sh issue-domain demo.example.com
```

> 调试阶段可先设 `CERTBOT_STAGING=1` 用测试 CA，成功后改回 `0` 再签正式证书。证书签发到宿主机 `/data/letsencrypt/live/demo.example.com/`。

**4. 签发成功后**，建 HTTPS 模板 `<path-to-your-dv>/proxy/templates-enabled/30-https-demo.conf.template`：

```nginx
# edge proxy 站点 —— demo.example.com（443 + 证书 + 反代）
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN_DEMO};

    ssl_certificate     /etc/letsencrypt/live/${DEMO_CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DEMO_CERT_NAME}/privkey.pem;

    location / {
        resolver 127.0.0.11 valid=10s ipv6=off;
        set $demo_upstream ${DEMO_UPSTREAM};
        proxy_pass http://$demo_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

**5. 热重载并验证**：

```bash
./scripts/proxy.sh reload
curl -sI https://demo.example.com/
```

后端 `demo_web` 同样需接入 `shared_proxy`（见 A 第 4 步）。TLS 正常但返回 **502** = 后端未启动或不在网络上。

**6. 续期**：纳入统一续期 `./scripts/proxy.sh renew`（建议 cron / systemd timer）。

> 持久化提示：`templates-enabled/` 是 gitignore 的本地运行态，模板的「源」建议放进你自己的业务项目（像 `hub` / `ap` 由项目侧复制进来），否则重装 proxy 会丢失。

## 自定义站点接入

默认不会再启用前端/后端双站点配置。新增站点时，将对应模板追加到 `templates-enabled/`，在 `.env.proxy` 中提供模板变量，然后执行 `reload`。

### 1. 编辑 `.env.proxy`（服务器）

```bash
CERTBOT_EMAIL=you@example.com
CERTBOT_DOMAINS=www.example.com,admin.example.com
CERT_NAME=www.example.com

DOMAIN_WWW=www.example.com
DOMAIN_HT=admin.example.com
DOMAIN_WWW_CERT_NAME=www.example.com
DOMAIN_HT_CERT_NAME=www.example.com

WEB_UPSTREAM=myapp_web:80
ADMIN_UPSTREAM=myapp_admin:8080
```

### 2. 准备模板

```bash
cd <path-to-your-dv>/proxy

# 可从示例开始，也可以直接写自己的模板。
cp examples/frontend-backend/templates/05-upstreams.conf.template templates-enabled/
cp examples/frontend-backend/templates/10-http.conf.template templates-enabled/
# 首次（nginx 尚未运行）用 up 启动并渲染；proxy 已在运行时改用 reload
./scripts/proxy.sh up
```

### 3. 业务接入 `shared_proxy`（可选）

```bash
docker compose -f docker-compose.yaml \
  -f <path-to-your-dv>/proxy/examples/p260507-network.override.yaml \
  up -d --build
```

### 4. 启动 → 签证

```bash
./scripts/proxy.sh up
./scripts/proxy.sh issue
```

`issue` 只签发证书并 reload 当前启用模板，不会自动切换 HTTPS。证书签发成功后，将 HTTPS 模板追加到 `templates-enabled/`，再 `reload`：

```bash
cp examples/frontend-backend/templates/10-http-redirect.conf.template templates-enabled/10-http.conf.template
cp examples/frontend-backend/templates/20-https.conf.template templates-enabled/
./scripts/proxy.sh reload
```

### 5. 一域一证

```bash
./scripts/proxy.sh issue-domain www.example.com
./scripts/proxy.sh issue-domain admin.example.com
# 手动将 HTTPS 模板复制到 templates-enabled/ 后：
./scripts/proxy.sh reload
```

`issue-domain` **不会**自动切换 HTTPS，避免只签部分域名时 nginx 因缺证书无法 reload。

## 已有站点：新增子域名

`proxy.sh up` 会保留已有 `templates-enabled/` 并重新渲染当前模板，但日常改域名、upstream 或模板仍应使用 `reload`。

### 一证多域

1. `.env.proxy` 中 `CERTBOT_DOMAINS` 写**完整**域名列表  
2. 追加或更新模板并 `reload` → `expand`

### 一域一证

1. `issue-domain <新域名>`  
2. 增加 server 模板、`DOMAIN_*_CERT_NAME`  
3. `reload` 或 `enable-https`（infra）

## 证书续期

```bash
./scripts/proxy.sh renew
```

建议 cron / systemd timer 定期执行。续期不需改 `CERTBOT_DOMAINS`；`expand` 仅用于增加 SAN。

## 日常运维

| 场景 | 命令 |
|------|------|
| 改 `.env.proxy` 或 `templates-enabled/` | `test` → `reload` |
| 仅基础设施启用 HTTPS | `enable-https` |
| 查看状态 | `ps` 或 `deploy-infra.sh ps proxy` |
| 排查 | `logs` |
| 停止 | `down` |
| 改挂载或 compose 后 | `docker compose --env-file .env.proxy -f docker-compose.yaml up -d --force-recreate nginx` 再 `reload`（裸 `docker compose` 不会读 `.env.proxy`，会忽略 `HTTP_PORT`/`NGINX_IMAGE` 等插值） |

## 新项目接入

1. 业务 compose 加入 `shared_proxy`，设置唯一 alias。  
2. `.env.proxy` 增加域名与 upstream。  
3. 增加 server 模板，使用 `${VAR}` 引用 `.env.proxy` 中的域名与 upstream。
4. 复制到 `templates-enabled/`，`reload`。  
5. 新公网域名需 `issue-domain` 或 `issue` / `expand`。

## 宿主机端口 upstream

```bash
GRAFANA_UPSTREAM=host.docker.internal:3000
STORE_UPSTREAM=host.docker.internal:7270
ADMIN_STORE_UPSTREAM=host.docker.internal:8090
```

## 测试

```bash
cd proxy
bash tests/proxy_issue_domain_test.sh
bash tests/proxy_template_behavior_test.sh
```

## 常见问题

- **`up` 与 `reload`**：日常改配置用 `reload`；`up` 只在没有启用模板时初始化 infra HTTP 模板，并在启动 nginx 前渲染当前模板。
- **`issue-domain` 后仍无法 HTTPS**：须执行 `enable-https`（infra）或自行加入 HTTPS 模板后 `reload`；仅磁盘有证书不够。  
- **`conf.d-enabled` 为空或 HTTPS 无响应**：确认已 `reload`；改 compose 挂载后需 `docker compose --env-file .env.proxy -f docker-compose.yaml up -d --force-recreate nginx`（必须带 `--env-file`，否则端口/镜像等插值回落默认值）。  
- **502**：TLS 正常但 upstream 无进程（例如 store 端口未监听）。  
- **80 端口**：webroot 需可访问 `http://<域名>/.well-known/acme-challenge/`。  
- **`CERTBOT_STAGING=1`**：测试 CA，调试后改回 `0`。  
- **证书路径**：宿主机 `/data/letsencrypt/live/<cert-name>/`。  
- **变量未替换**：模板变量必须写成 `${VAR}`，并确认 `.env.proxy` 中有同名变量；裸 `$host` 这类 nginx 变量会保留到运行时。
- **根域无 A 记录**：`issue-domain example.com` 会失败；先配 DNS 或为 www 单独签发。
