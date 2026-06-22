# dv — 共享基础设施

在单台服务器上用 Docker Compose 部署共享中间件与统一反向代理（nginx + Let's Encrypt），供多个业务项目复用。

> **公开仓库**：`.env.*`、`proxy/conf.d-enabled/*.conf`、`proxy/templates-enabled/` 等含域名、邮箱、upstream 的路径已写入 `.gitignore`，请勿提交。仅在服务器上维护真实配置。

## 包含的服务

| Stack | 目录 | 说明 |
|-------|------|------|
| **proxy** | [`proxy/`](proxy/) | 公网 80/443、证书、反代入口 |
| **db** | [`db/`](db/) | MySQL、Redis、MongoDB |
| **monitor** | [`monitor/`](monitor/) | Prometheus、Grafana、Loki、Tempo、Promtail |
| **etcd** | [`etcd/`](etcd/) | etcd |
| **rabbitmq** | [`rabbitmq/`](rabbitmq/) | RabbitMQ |
| **minio** | [`minio/`](minio/) | MinIO 对象存储 |

各 stack 使用独立的 external Docker network（如 `shared_proxy`、`shared_db`）。业务项目通过 [`proxy/examples/p260507-network.override.yaml`](proxy/examples/p260507-network.override.yaml) 接入 `shared_proxy`。

## 快速开始

### 1. 准备环境变量（仅服务器 / 本地，勿提交）

```bash
# 从各 stack 的 .env.*.example 生成缺失的 .env.*（幂等，不覆盖已有真实配置）
./deploy-infra.sh init-env
# 编辑生成的文件，把 CHANGE_ME 占位值改为真实值（字段说明见各目录 README）
# 校验是否还有占位符 / 空值
./deploy-infra.sh validate
```

`up` 启动前会自动执行同样的校验，任一变量仍为 `CHANGE_ME` 或空值即 fail fast。

### 2. 初始化数据目录与网络（首次）

```bash
sudo ./deploy-infra.sh init
```

创建 `/data` 下 certbot、letsencrypt、各服务数据目录，以及 `shared_proxy` 等 Docker networks。

### 3. 启动服务

```bash
./deploy-infra.sh up              # 全部 stack
./deploy-infra.sh up proxy monitor   # 指定 stack
./deploy-infra.sh ps
./deploy-infra.sh logs proxy
```

### 4. 配置 HTTPS（proxy）

1. 启动 proxy（HTTP）：`./deploy-infra.sh up proxy` 或 `cd proxy && ./scripts/proxy.sh up`
2. 签发证书：`./scripts/proxy.sh issue-domain <域名>`（见 [proxy/README.md](proxy/README.md)）
3. 启用 HTTPS 反代：`./scripts/proxy.sh enable-https`

基础设施域名（monitor / store 等）的模板与流程见 [proxy/README.md — 基础设施 HTTPS](proxy/README.md#基础设施-https一域一证)。

## `deploy-infra.sh` 命令

```bash
./deploy-infra.sh init-env [stack ...]   # 从 .env.*.example 生成缺失的 .env.*（幂等）
./deploy-infra.sh validate [stack ...]   # 校验 .env.* 无占位符 / 空值
sudo ./deploy-infra.sh init-data      # 仅创建 /data 子目录
./deploy-infra.sh init-networks       # 仅创建 Docker networks
sudo ./deploy-infra.sh init           # init-data + init-networks

./deploy-infra.sh up [stack ...]      # 校验配置后启动
./deploy-infra.sh down [stack ...]
./deploy-infra.sh restart [stack ...]
./deploy-infra.sh ps [stack ...]
./deploy-infra.sh logs <stack>
```

可用 stack：`proxy` `db` `monitor` `etcd` `rabbitmq` `minio`

环境变量：`DATA_ROOT`（默认 `/data`）、`DEPLOY_UID` / `DEPLOY_GID`（`init-data` 时 logs 目录属主）

## 目录结构

```
.
├── deploy-infra.sh          # 统一部署入口
├── proxy/                   # nginx + certbot（详见 proxy/README.md）
├── db/
├── monitor/
├── etcd/
├── rabbitmq/
└── minio/
```

## 文档

- [proxy/README.md](proxy/README.md) — 证书策略、模板渲染、反代与运维命令

## 安全与仓库

| 路径 | 是否进 Git | 说明 |
|------|------------|------|
| `**/.env.*` | 否 | 密码、域名、邮箱 |
| `proxy/conf.d-enabled/*.conf` | 否 | 渲染后的 nginx 配置 |
| `proxy/templates-enabled/` | 否 | 服务器当前启用的模板副本 |
| `proxy/templates/` | 是 | 带 `${变量}` 的通用模板 |
| `/data/letsencrypt` | 否（宿主机） | 证书私钥 |

克隆本仓库后，在每台服务器上单独创建 `.env.*` 与运行态配置，不要 `git add -f` 忽略规则中的文件。
