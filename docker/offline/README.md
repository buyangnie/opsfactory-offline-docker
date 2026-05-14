# OpsFactory 离线 Docker 安装使用手册

本文面向拿到 `opsfactory-offline-YYYYMMDD-linux-amd64.tar.gz` 离线包的安装人员。离线包安装后是单机 all-in-one 运行形态，适合演示、试用、单机验证和内网交付前置验证。

## 1. 包信息

- 镜像：`__IMAGE_TAG__`
- 平台：`linux/amd64`
- 基础系统：`openEuler 24.03 LTS SP3`
- goosed：`1.33.1`
- Langfuse：默认禁用
- OnlyOffice：默认禁用

离线包包含：

- `images/opsfactory-linux-amd64.tar`：预构建 Docker 镜像
- `docker-compose.yml`：运行配置
- `scripts/`：导入、启动、停止、状态、模型配置辅助脚本
- `runtime-overrides/`：离线运行补丁，包含更长的首次启动健康检查等待时间和 admin-only resident seed 配置
- `build-report.txt`：构建输入、seed 数据和脱敏报告
- `SHA256SUMS.txt`：包内文件校验

## 2. 前置条件

目标服务器需要已经安装 Docker Engine 和 Docker Compose plugin：

```bash
docker --version
docker compose version
```

要求：

- Linux x86_64 / amd64 服务器
- Docker Engine 已可用
- Docker Compose plugin 已可用
- 目标服务器不需要连接外网即可启动页面和本地服务
- 如果需要模型调用，目标服务器或容器必须能访问对应模型服务
- 需要开放端口：`5173`、`3000`、`8092`、`8093`、`8094`、`8095`、`8096`、`9091`
- 建议至少 4 CPU / 8 GiB 内存；首次启动会同时启动多个 Java 服务和 goosed agent

确认 Docker 当前可用资源：

```bash
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}} Architecture={{.Architecture}}'
```

注意：本包镜像平台是 `linux/amd64`。如果在 Apple Silicon Mac 或其他非 amd64 主机上测试，Docker 会跨架构模拟运行，启动时间和 CPU 占用会明显高于目标 x86_64 Linux 服务器。

## 3. 安装和启动

将安装包拷贝到目标服务器，例如：

```bash
scp opsfactory-offline-YYYYMMDD-linux-amd64.tar.gz user@server:/opt/
```

在目标服务器上解压：

```bash
cd /opt
tar -xzf opsfactory-offline-YYYYMMDD-linux-amd64.tar.gz
cd opsfactory-offline-YYYYMMDD-linux-amd64
```

校验并导入 Docker 镜像：

```bash
./scripts/load-image.sh
```

导入后可确认镜像：

```bash
docker images | grep opsfactory
```

启动：

```bash
./scripts/start.sh
```

成功后会输出：

```text
OpsFactory is ready: http://127.0.0.1:5173
```

如果从其他机器访问，把 `127.0.0.1` 换成服务器 IP：

```text
http://<服务器IP>:5173
```

首次启动会初始化 Docker volumes，并启动多个 Java 服务和 goosed agent。在目标 x86_64 Linux 服务器上通常需要数分钟；跨架构模拟环境会更慢。只要容器仍在运行，看到服务正在启动时不要反复停止重启，例如：

```text
Starting gateway at http://0.0.0.0:3000
Starting knowledge-service at http://127.0.0.1:8092
```

观察日志和资源：

```bash
docker logs -f opsfactory
docker stats opsfactory
```

## 4. 状态检查

查看 compose 状态：

```bash
./scripts/status.sh
docker ps | grep opsfactory
```

逐个检查健康接口：

```bash
curl -fsS http://127.0.0.1:5173 >/dev/null && echo "web ok"
curl -fsS http://127.0.0.1:3000/gateway/status -H 'x-secret-key: test' >/dev/null && echo "gateway ok"
curl -fsS http://127.0.0.1:8092/actuator/health && echo
curl -fsS http://127.0.0.1:8093/actuator/health && echo
curl -fsS http://127.0.0.1:8094/actuator/health && echo
curl -fsS http://127.0.0.1:8095/actuator/health && echo
curl -fsS http://127.0.0.1:8096/actuator/health && echo
curl -fsS http://127.0.0.1:9091/health && echo
```

服务端口：

| 服务 | 端口 |
| --- | ---: |
| Web App | 5173 |
| Gateway | 3000 |
| Knowledge Service | 8092 |
| Business Intelligence | 8093 |
| Control Center | 8094 |
| Skill Market | 8095 |
| Operation Intelligence | 8096 |
| Prometheus Exporter | 9091 |

## 5. 配置模型接口

镜像内已经保留当前配置结构和 seed 数据，但不包含真实模型 Key。首次启动后页面可以访问、数据可以查看；涉及模型调用的功能需要配置模型接口。

OpsFactory 的 agent 使用 OpenAI-compatible chat completions 接口。OpenRouter 只是一个例子；只要目标模型服务兼容 OpenAI chat completions，就可以使用同一套配置方式，包括内网模型网关、私有化推理平台或其他云厂商兼容接口。

配置前准备以下信息：

- `MODEL_NAME`：模型名，必须和服务端可识别的模型名一致，例如 `qwen/qwen3.5-27b`
- `BASE_URL`：OpenAI-compatible chat completions URL，例如 `https://openrouter.ai/api/v1/chat/completions` 或内网网关地址
- `API_KEY`：LLM API key
- `PROVIDER_NAME`：本地 provider 名称，可自定义，建议使用只包含字母、数字、点、下划线和连字符的名称

使用包内脚本配置。脚本会同时更新所有 agent 的 provider、model、provider JSON 和 secrets，并重启 Gateway/Knowledge。

示例：配置 OpenRouter 的 `qwen/qwen3.5-27b`：

```bash
MODEL_NAME='qwen/qwen3.5-27b' \
BASE_URL='https://openrouter.ai/api/v1/chat/completions' \
PROVIDER_NAME='custom_qwen3.5-27b' \
./scripts/configure-openai-compatible.sh
```

示例：配置内网 OpenAI-compatible 服务：

```bash
MODEL_NAME='qwen/qwen3.5-27b' \
BASE_URL='http://10.0.0.10:8000/v1/chat/completions' \
PROVIDER_NAME='custom_internal_qwen' \
./scripts/configure-openai-compatible.sh
```

脚本会安全地提示输入 `LLM API Key`，不会把 key 打印到终端。也可以通过环境变量传入，适合自动化安装：

```bash
MODEL_NAME='qwen/qwen3.5-27b' \
BASE_URL='http://10.0.0.10:8000/v1/chat/completions' \
PROVIDER_NAME='custom_internal_qwen' \
API_KEY='替换为实际 key' \
./scripts/configure-openai-compatible.sh
```

如果 embedding 使用同一个服务或同一个 key，可以在同一次执行中设置 embedding 参数：

```bash
MODEL_NAME='qwen/qwen3.5-27b' \
BASE_URL='http://10.0.0.10:8000/v1/chat/completions' \
PROVIDER_NAME='custom_internal_qwen' \
EMBEDDING_BASE_URL='http://10.0.0.10:8000/v1' \
EMBEDDING_MODEL='qwen/qwen3-embedding-4b' \
EMBEDDING_DIMENSIONS='1024' \
./scripts/configure-openai-compatible.sh
```

如果 embedding 使用不同 key：

```bash
MODEL_NAME='qwen/qwen3.5-27b' \
BASE_URL='http://10.0.0.10:8000/v1/chat/completions' \
PROVIDER_NAME='custom_internal_qwen' \
EMBEDDING_API_KEY='替换为 embedding key' \
EMBEDDING_BASE_URL='http://10.0.0.10:8000/v1' \
EMBEDDING_MODEL='qwen/qwen3-embedding-4b' \
EMBEDDING_DIMENSIONS='1024' \
./scripts/configure-openai-compatible.sh
```

不要只改 key。模型接口由 provider 名称、base URL、model 名称、provider JSON 和 `secrets.yaml` 共同决定；只改其中一项容易导致页面能打开但模型调用失败。

配置完成后，从页面人工验证：

1. 打开 `http://<服务器IP>:5173`
2. 进入任意 agent，例如 `Universal Agent`
3. 新建会话并发送：`用一句话介绍你自己`
4. 如果能返回模型回答，说明 LLM key 和 provider 配置已生效

不要在日志里粘贴完整 key：

```bash
docker logs opsfactory --tail 200
```

## 6. 减少启动压力

当前离线包默认通过 `runtime-overrides/gateway-config.yaml` 将 seed 配置调整为 admin-only resident，避免同时为多个用户预拉起大量 goosed 实例。首次启动时会把这个配置复制到 Docker volume 中。

如果曾经用旧包启动过，已有 volume 不会自动覆盖。可以按第 9 节重置数据后重新启动，或手工编辑 `/app/runtime-config/gateway/config.yaml` 中的 `residentInstances`，只保留：

```yaml
residentInstances:
  enabled: true
  entries:
  - userId: admin
    agentIds: ['*']
```

手工修改后重启 Gateway：

```bash
docker exec opsfactory bash -lc \
  'ENABLE_ONLYOFFICE=false ENABLE_LANGFUSE=false ENABLE_EXPORTER=true ENABLE_OPERATION_INTELLIGENCE=true /app/scripts/ctl.sh restart gateway'
```

确认只剩 `admin`：

```bash
docker exec opsfactory bash -lc \
  'sed -n "/residentInstances:/,/agents:/p" /app/runtime-config/gateway/config.yaml'
```

确认 resident goosed 数量。admin-only 时通常是 9 个：

```bash
docker exec opsfactory bash -lc \
  'ps -ef | awk "/goosed agent/ && !/awk/ {print}" | wc -l'
```

## 7. 停止服务

```bash
./scripts/stop.sh
```

## 8. 查看日志

查看最近容器日志：

```bash
docker logs opsfactory --tail 200
```

持续观察日志：

```bash
docker logs -f opsfactory
```

## 9. 重置数据

首次启动时，镜像内置 seed 数据会复制到 Docker named volumes。后续重启不会覆盖已有数据。

如果需要清空当前数据并重新从镜像 seed 初始化：

```bash
./scripts/stop.sh
docker compose -f docker-compose.yml down -v
./scripts/start.sh
```

注意：`down -v` 会删除当前 Docker volumes 中的数据，包括已经配置的模型 key 和运行数据。

## 10. 常见问题

### 端口被占用

`./scripts/start.sh` 会在启动前检查端口。如果提示端口占用，先查占用进程：

```bash
ss -ltnp | grep -E '5173|3000|8092|8093|8094|8095|8096|9091'
```

停止占用端口的服务后重新启动：

```bash
./scripts/start.sh
```

### Docker Compose 不存在

检查：

```bash
docker compose version
```

如果失败，需要先安装 Docker Compose plugin。

### 服务启动失败

查看状态和日志：

```bash
./scripts/status.sh
docker logs opsfactory --tail 200
```

如果日志显示某个服务正在启动，例如 `Starting gateway` 或 `Starting knowledge-service`，且容器仍然是 `Up`，先等待几分钟再判断。首次启动在跨架构模拟环境下可能非常慢。

如果日志反复出现以下信息，说明服务自身启动慢于内部健康检查窗口：

```text
Gateway failed to become healthy
knowledge-service health check failed
```

当前离线包已经包含 `runtime-overrides/*-ctl.sh`，会把 Java 服务健康检查等待时间放宽。确认 compose 中存在这些挂载：

```bash
grep -n "runtime-overrides" docker-compose.yml
```

如果 `runtime-overrides` 文件缺失，说明离线包不完整，需要重新取得完整包。

如果确实需要重新启动：

```bash
./scripts/stop.sh
./scripts/start.sh
```

### 模型调用失败

先确认服务健康：

```bash
curl -fsS http://127.0.0.1:3000/gateway/status -H 'x-secret-key: test' && echo
```

再检查某个 agent 的 provider/model 是否对齐：

```bash
docker exec opsfactory bash -lc \
  'sed -n "1,2p" /app/gateway/agents/universal-agent/config/config.yaml && \
   sed -n "1,80p" /app/gateway/agents/universal-agent/config/custom_providers/*.json'
```

最后确认容器可以访问模型服务。以下命令只是 OpenRouter 示例；内网模型服务请换成实际地址：

```bash
docker exec opsfactory bash -lc \
  'curl -sS -o /dev/null -w "%{http_code}\n" https://openrouter.ai/api/v1/models'
```

如果目标环境完全离线且无法访问任何模型服务，页面和本地服务可以运行，但 LLM 和 embedding 调用会失败。此时需要改成内网 OpenAI-compatible 模型服务，并同步修改 `BASE_URL`、`MODEL_NAME` 和 embedding 配置。
