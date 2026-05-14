#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-opsfactory}"
PROVIDER_NAME="${PROVIDER_NAME:-custom_openai_compatible}"
API_KEY_ENV="${API_KEY_ENV:-CUSTOM_OPSAGENTLLM_API_KEY}"
CONTEXT_LIMIT="${CONTEXT_LIMIT:-128000}"
RESTART_SERVICES="${RESTART_SERVICES:-true}"

prompt_secret() {
    local var_name="$1"
    local prompt="$2"
    local value="${!var_name:-}"
    if [ -z "${value}" ]; then
        printf "%s" "${prompt}" >&2
        IFS= read -r -s value
        printf "\n" >&2
    fi
    if [ -z "${value}" ]; then
        echo "${var_name} cannot be empty" >&2
        exit 1
    fi
    printf -v "${var_name}" "%s" "${value}"
}

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Container is not running: ${CONTAINER_NAME}" >&2
    exit 1
fi

if [ -z "${MODEL_NAME:-}" ]; then
    read -r -p "Model name, for example qwen/qwen3.5-27b: " MODEL_NAME
fi
if [ -z "${BASE_URL:-}" ]; then
    read -r -p "OpenAI-compatible chat completions URL: " BASE_URL
fi

if [ -z "${MODEL_NAME}" ] || [ -z "${BASE_URL}" ]; then
    echo "MODEL_NAME and BASE_URL are required" >&2
    exit 1
fi

prompt_secret API_KEY "LLM API Key: "

docker exec -i \
    -e PROVIDER_NAME="${PROVIDER_NAME}" \
    -e MODEL_NAME="${MODEL_NAME}" \
    -e BASE_URL="${BASE_URL}" \
    -e API_KEY_ENV="${API_KEY_ENV}" \
    -e API_KEY="${API_KEY}" \
    -e CONTEXT_LIMIT="${CONTEXT_LIMIT}" \
    "${CONTAINER_NAME}" python3 - <<'PY'
import json
import os
import shutil
from pathlib import Path

agents_root = Path("/app/gateway/agents")
provider_name = os.environ["PROVIDER_NAME"]
model_name = os.environ["MODEL_NAME"]
base_url = os.environ["BASE_URL"]
api_key_env = os.environ["API_KEY_ENV"]
api_key = os.environ["API_KEY"]
context_limit = int(os.environ["CONTEXT_LIMIT"])
source_provider = agents_root / "universal-agent/config/custom_providers/custom_qwen3.5-27b.json"

for agent_dir in sorted(p for p in agents_root.iterdir() if p.is_dir()):
    config_dir = agent_dir / "config"
    if not config_dir.is_dir():
        continue

    provider_dir = config_dir / "custom_providers"
    provider_dir.mkdir(parents=True, exist_ok=True)
    provider_path = provider_dir / f"{provider_name}.json"
    if not provider_path.exists() and source_provider.exists():
        shutil.copy2(source_provider, provider_path)

    provider = json.loads(provider_path.read_text()) if provider_path.exists() else {}
    provider.update({
        "name": provider_name,
        "engine": "openai",
        "display_name": model_name,
        "description": f"OpenAI-compatible provider for {model_name}",
        "api_key_env": api_key_env,
        "base_url": base_url,
        "models": [{"name": model_name, "context_limit": context_limit}],
        "supports_streaming": True,
        "requires_auth": True,
    })
    provider_path.write_text(json.dumps(provider, indent=2) + "\n")

    config_path = config_dir / "config.yaml"
    lines = config_path.read_text().splitlines()
    out = []
    seen_provider = False
    seen_model = False
    for line in lines:
        if line.startswith("GOOSE_PROVIDER:"):
            out.append(f"GOOSE_PROVIDER: {provider_name}")
            seen_provider = True
        elif line.startswith("GOOSE_MODEL:"):
            out.append(f"GOOSE_MODEL: {model_name}")
            seen_model = True
        else:
            out.append(line)
    if not seen_model:
        out.insert(0, f"GOOSE_MODEL: {model_name}")
    if not seen_provider:
        out.insert(0, f"GOOSE_PROVIDER: {provider_name}")
    config_path.write_text("\n".join(out) + "\n")

    secrets_path = config_dir / "secrets.yaml"
    secret_lines = secrets_path.read_text().splitlines() if secrets_path.exists() else ["---"]
    new_secret_lines = []
    found = False
    for line in secret_lines:
        if line.startswith(f"{api_key_env}:"):
            new_secret_lines.append(f'{api_key_env}: "{api_key}"')
            found = True
        else:
            new_secret_lines.append(line)
    if not found:
        insert_at = 1 if new_secret_lines and new_secret_lines[0] == "---" else 0
        new_secret_lines.insert(insert_at, f'{api_key_env}: "{api_key}"')
    secrets_path.write_text("\n".join(new_secret_lines) + "\n")
PY

if [ -n "${EMBEDDING_API_KEY:-}" ] || [ -n "${EMBEDDING_BASE_URL:-}" ] || [ -n "${EMBEDDING_MODEL:-}" ]; then
    EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-${API_KEY}}"
    EMBEDDING_BASE_URL="${EMBEDDING_BASE_URL:-}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-}"
    EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-}"
    docker exec -i \
        -e EMBEDDING_API_KEY="${EMBEDDING_API_KEY}" \
        -e EMBEDDING_BASE_URL="${EMBEDDING_BASE_URL}" \
        -e EMBEDDING_MODEL="${EMBEDDING_MODEL}" \
        -e EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS}" \
        "${CONTAINER_NAME}" python3 - <<'PY'
import os
from pathlib import Path

path = Path("/app/runtime-config/knowledge-service/config.yaml")
lines = path.read_text().splitlines()
updates = {
    "api-key": os.environ["EMBEDDING_API_KEY"],
    "base-url": os.environ.get("EMBEDDING_BASE_URL", ""),
    "model": os.environ.get("EMBEDDING_MODEL", ""),
    "dimensions": os.environ.get("EMBEDDING_DIMENSIONS", ""),
}
out = []
in_embedding = False
embedding_indent = None

for line in lines:
    stripped = line.strip()
    indent = len(line) - len(line.lstrip(" "))
    if stripped.startswith("embedding:"):
        in_embedding = True
        embedding_indent = indent
        out.append(line)
        continue
    if in_embedding and stripped and indent <= embedding_indent:
        in_embedding = False
    key = stripped.split(":", 1)[0] if ":" in stripped else ""
    if in_embedding and key in updates and updates[key]:
        value = updates[key]
        if key == "dimensions":
            out.append(" " * indent + f"{key}: {value}")
        else:
            out.append(" " * indent + f'{key}: "{value}"')
    else:
        out.append(line)

path.write_text("\n".join(out) + "\n")
PY
fi

unset API_KEY

if [ "${RESTART_SERVICES}" = "true" ]; then
    docker exec "${CONTAINER_NAME}" bash -lc \
        'ENABLE_ONLYOFFICE=false ENABLE_LANGFUSE=false ENABLE_EXPORTER=true ENABLE_OPERATION_INTELLIGENCE=true /app/scripts/ctl.sh restart gateway knowledge'
fi

echo "OpenAI-compatible model configuration applied."
