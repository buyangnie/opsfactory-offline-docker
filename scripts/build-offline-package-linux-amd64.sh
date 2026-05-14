#!/usr/bin/env bash
set -euo pipefail

PACKAGE_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_SOURCE_DIR="$(cd "${PACKAGE_REPO_DIR}/../ops-factory" 2>/dev/null && pwd || true)"
OPSFACTORY_SOURCE_DIR="${OPSFACTORY_SOURCE_DIR:-${DEFAULT_SOURCE_DIR}}"
BUILD_DIR="${PACKAGE_REPO_DIR}/.docker-build"
STAGING_DIR="${BUILD_DIR}/opsfactory-sanitized"
VENDOR_DIR="${BUILD_DIR}/vendor"
DIST_DIR="${PACKAGE_REPO_DIR}/dist"
BUILD_DATE="$(date +%Y%m%d)"
DEFAULT_TAG="opsfactory:offline-${BUILD_DATE}-linux-amd64"
IMAGE_TAG="${DEFAULT_TAG}"
GOOSE_VERSION="1.33.1"
GOOSE_RPM_NAME="Goose-1.33.1-1.x86_64.rpm"
GOOSE_RPM_URL="https://github.com/aaif-goose/goose/releases/download/v1.33.1/${GOOSE_RPM_NAME}"
GOOSE_RPM_SHA256="e7bd1c42f514c3dd11f91f0098ac3f76254feac8ef0e805d1b159bd4037e10b8"
GOOSE_RPM_SOURCE=""
SMOKE_TEST=false
SKIP_DOCKER_BUILD=false

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --tag <tag>          Docker image tag. Default: ${DEFAULT_TAG}
  --source-dir <path>  OpsFactory source checkout. Default: ${DEFAULT_SOURCE_DIR:-<not found>}
  --goose-rpm <path>   Use an existing ${GOOSE_RPM_NAME}
  --smoke-test         Build the package, then run the offline start flow
  --skip-docker-build  Reassemble the offline package from the existing local image
  -h, --help           Show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --source-dir)
            OPSFACTORY_SOURCE_DIR="$2"
            shift 2
            ;;
        --goose-rpm)
            GOOSE_RPM_SOURCE="$2"
            shift 2
            ;;
        --smoke-test)
            SMOKE_TEST=true
            shift
            ;;
        --skip-docker-build)
            SKIP_DOCKER_BUILD=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "${OPSFACTORY_SOURCE_DIR}" ] || [ ! -d "${OPSFACTORY_SOURCE_DIR}" ]; then
    echo "OpsFactory source checkout not found. Pass --source-dir /path/to/ops-factory." >&2
    exit 1
fi
OPSFACTORY_SOURCE_DIR="$(cd "${OPSFACTORY_SOURCE_DIR}" && pwd)"

PACKAGE_SAFE_TAG="${IMAGE_TAG//[:\/]/-}"
PACKAGE_NAME="${PACKAGE_SAFE_TAG}"
PACKAGE_DIR="${DIST_DIR}/${PACKAGE_NAME}"
IMAGE_TAR="${PACKAGE_DIR}/images/opsfactory-linux-amd64.tar"
REPORT_FILE="${BUILD_DIR}/build-report.txt"

log() {
    printf '[offline-build] %s\n' "$*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

copy_path() {
    local source="$1"
    local target="$2"
    if [ ! -e "${source}" ]; then
        return 0
    fi
    mkdir -p "$(dirname "${target}")"
    if [ -d "${source}" ]; then
        mkdir -p "${target}"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a \
                --exclude '.git' \
                --exclude '.docker-build' \
                --exclude 'dist' \
                --exclude 'node_modules' \
                --exclude 'target' \
                --exclude 'logs' \
                --exclude 'output' \
                --exclude '.playwright-cli' \
                --exclude '.DS_Store' \
                --exclude '*.pid' \
                --exclude '*.log' \
                --exclude '.gateway-keystore.p12' \
                --exclude '.gateway-keystore.pem' \
                "${source}/" "${target}/"
        else
            (cd "${source}" && tar \
                --exclude '.git' \
                --exclude '.docker-build' \
                --exclude 'dist' \
                --exclude 'node_modules' \
                --exclude 'target' \
                --exclude 'logs' \
                --exclude 'output' \
                --exclude '.playwright-cli' \
                --exclude '.DS_Store' \
                --exclude '*.pid' \
                --exclude '*.log' \
                --exclude '.gateway-keystore.p12' \
                --exclude '.gateway-keystore.pem' \
                -cf - .) | (cd "${target}" && tar -xf -)
        fi
    else
        cp -p "${source}" "${target}"
    fi
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
    else
        shasum -a 256 "${file}" | awk '{print $1}'
    fi
}

download_goose_rpm() {
    local dest="${STAGING_DIR}/vendor/goose/${GOOSE_RPM_NAME}"
    local cached="${VENDOR_DIR}/goose/${GOOSE_RPM_NAME}"
    mkdir -p "$(dirname "${dest}")"
    mkdir -p "$(dirname "${cached}")"
    if [ -n "${GOOSE_RPM_SOURCE}" ]; then
        cp "${GOOSE_RPM_SOURCE}" "${cached}"
    else
        require_cmd curl
        if [ ! -f "${cached}" ] || [ "$(sha256_file "${cached}")" != "${GOOSE_RPM_SHA256}" ]; then
            curl -fL --retry 5 --retry-delay 5 -C - "${GOOSE_RPM_URL}" -o "${cached}"
        fi
    fi
    local actual
    actual="$(sha256_file "${cached}")"
    if [ "${actual}" != "${GOOSE_RPM_SHA256}" ]; then
        echo "Unexpected goose rpm checksum: ${actual}" >&2
        echo "Expected: ${GOOSE_RPM_SHA256}" >&2
        exit 1
    fi
    cp "${cached}" "${dest}"
}

sanitize_model_keys() {
    python3 - "$STAGING_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
sanitized = []
warnings = []
model_key_text = re.compile(r"sk-(?:or-v1-)?[A-Za-z0-9_-]{16,}")
model_key_bytes = re.compile(rb"sk-(?:or-v1-)?[A-Za-z0-9_-]{16,}")

def record_sanitized(path: Path) -> None:
    rel = str(path.relative_to(root))
    if rel not in sanitized:
        sanitized.append(rel)

def collect_provider_keys(config_dir: Path) -> set[str]:
    keys: set[str] = set()
    providers = config_dir / "custom_providers"
    if not providers.is_dir():
        return keys
    for path in providers.glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            warnings.append(f"Failed to parse provider JSON {path.relative_to(root)}: {exc}")
            continue
        value = data.get("api_key_env")
        if isinstance(value, str) and value.strip():
            keys.add(value.strip())
    return keys

def blank_yaml_keys(path: Path, keys: set[str]) -> bool:
    if not path.is_file() or not keys:
        return False
    original = path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed = False
    output = []
    key_pattern = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_.-]*)(\s*:\s*)(.*?)(\s*(?:#.*)?)$")
    for line in original:
        match = key_pattern.match(line.rstrip("\n"))
        newline = "\n" if line.endswith("\n") else ""
        if match and match.group(2) in keys:
            output.append(f'{match.group(1)}{match.group(2)}{match.group(3)}""{match.group(5)}{newline}')
            changed = True
        else:
            output.append(line)
    if changed:
        path.write_text("".join(output), encoding="utf-8")
    return changed

def blank_knowledge_embedding_api_key(path: Path) -> bool:
    if not path.is_file():
        return False
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed = False
    in_knowledge = False
    in_embedding = False
    knowledge_indent = None
    embedding_indent = None
    output = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            indent = len(line) - len(line.lstrip(" "))
            if re.match(r"^knowledge\s*:", stripped):
                in_knowledge = True
                in_embedding = False
                knowledge_indent = indent
            elif in_knowledge and knowledge_indent is not None and indent <= knowledge_indent:
                in_knowledge = False
                in_embedding = False
            if in_knowledge and re.match(r"^embedding\s*:", stripped):
                in_embedding = True
                embedding_indent = indent
            elif in_embedding and embedding_indent is not None and indent <= embedding_indent:
                in_embedding = False
            if in_embedding and re.match(r"^api-key\s*:", stripped):
                newline = "\n" if line.endswith("\n") else ""
                comment = ""
                if "#" in line:
                    comment = " #" + line.split("#", 1)[1].rstrip("\n")
                output.append(f'{" " * indent}api-key: ""{comment}{newline}')
                changed = True
                continue
        output.append(line)
    if changed:
        path.write_text("".join(output), encoding="utf-8")
    return changed

def redact_model_key_patterns(path: Path) -> bool:
    try:
        data = path.read_bytes()
    except Exception:
        return False
    if not model_key_bytes.search(data):
        return False

    def replacement(match: re.Match[bytes]) -> bytes:
        value = match.group(0)
        prefix = b"REDACTED_MODEL_KEY"
        if len(value) <= len(prefix):
            return b"X" * len(value)
        return prefix + (b"X" * (len(value) - len(prefix)))

    path.write_bytes(model_key_bytes.sub(replacement, data))
    return True

for config_dir in sorted((root / "gateway" / "agents").glob("*/config")):
    keys = collect_provider_keys(config_dir)
    if blank_yaml_keys(config_dir / "secrets.yaml", keys):
        record_sanitized(config_dir / "secrets.yaml")

users_root = root / "gateway" / "users"
if users_root.is_dir():
    for config_dir in sorted(users_root.glob("*/agents/*/config")):
        agent_id = config_dir.parent.name
        shared_config = root / "gateway" / "agents" / agent_id / "config"
        keys = collect_provider_keys(shared_config) | collect_provider_keys(config_dir)
        if blank_yaml_keys(config_dir / "secrets.yaml", keys):
            record_sanitized(config_dir / "secrets.yaml")

knowledge_config = root / "knowledge-service" / "config.yaml"
if blank_knowledge_embedding_api_key(knowledge_config):
    record_sanitized(knowledge_config)

for path in root.rglob("*"):
    if not path.is_file():
        continue
    rel = str(path.relative_to(root))
    if any(part in rel.split("/") for part in ("node_modules", "target", ".git", "vendor")):
        continue
    if redact_model_key_patterns(path):
        record_sanitized(path)
        continue
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        continue
    if model_key_text.search(text):
        warnings.append(f"Possible non-sanitized model-like secret in {rel}")

report = root / "sanitization-report.txt"
report.write_text(
    "sanitized_files:\n"
    + "".join(f"- {item}\n" for item in sanitized)
    + "warnings:\n"
    + ("".join(f"- {item}\n" for item in warnings) if warnings else "- none\n"),
    encoding="utf-8",
)
PY
}

prepare_staging() {
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}"
    local paths=(
        AGENTS.md
        CLAUDE.md
        README.md
        docs
        scripts
        gateway
        web-app
        typescript-sdk
        knowledge-service
        business-intelligence
        skill-market
        control-center
        operation-intelligence
        prometheus-exporter
        onlyoffice
        langfuse
        media
        skills
    )
    for path in "${paths[@]}"; do
        copy_path "${OPSFACTORY_SOURCE_DIR}/${path}" "${STAGING_DIR}/${path}"
    done
    mkdir -p "${STAGING_DIR}/docker/offline"
    copy_path "${PACKAGE_REPO_DIR}/docker/offline" "${STAGING_DIR}/docker/offline"
    cp "${PACKAGE_REPO_DIR}/docker/offline/context.dockerignore" "${STAGING_DIR}/.dockerignore"
    download_goose_rpm
    sanitize_model_keys
}

write_report() {
    mkdir -p "${BUILD_DIR}"
    {
        echo "OpsFactory offline package build report"
        echo
        echo "image_tag: ${IMAGE_TAG}"
        echo "platform: linux/amd64"
        echo "base_image: openeuler/openeuler:24.03-lts-sp3"
        echo "goose_version: ${GOOSE_VERSION}"
        echo "goose_rpm: ${GOOSE_RPM_NAME}"
        echo "goose_rpm_url: ${GOOSE_RPM_URL}"
        echo "goose_rpm_sha256: ${GOOSE_RPM_SHA256}"
        echo "opsfactory_source_dir: ${OPSFACTORY_SOURCE_DIR}"
        if [ -n "${GOOSE_RPM_SOURCE}" ]; then
            echo "goose_rpm_source: ${GOOSE_RPM_SOURCE}"
        else
            echo "goose_rpm_source: downloaded"
        fi
        echo "package_dir: ${PACKAGE_DIR}"
        echo "package_archive: ${PACKAGE_DIR}.tar.gz"
        echo
        echo "included_seed_directories:"
        echo "- gateway/agents"
        echo "- gateway/users"
        echo "- gateway/data"
        echo "- knowledge-service/data"
        echo "- business-intelligence/data"
        echo "- skill-market/data"
        echo "- control-center/data"
        echo "- operation-intelligence/data"
        echo
        echo "excluded_patterns:"
        echo "- .git"
        echo "- node_modules"
        echo "- target"
        echo "- logs"
        echo "- output"
        echo "- .playwright-cli"
        echo "- gateway/.gateway-keystore.p12"
        echo "- gateway/.gateway-keystore.pem"
        echo
        if [ -f "${STAGING_DIR}/sanitization-report.txt" ]; then
            cat "${STAGING_DIR}/sanitization-report.txt"
        fi
        echo
        if command -v git >/dev/null 2>&1 && git -C "${OPSFACTORY_SOURCE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "opsfactory_git_branch: $(git -C "${OPSFACTORY_SOURCE_DIR}" branch --show-current 2>/dev/null || true)"
            echo "opsfactory_git_commit: $(git -C "${OPSFACTORY_SOURCE_DIR}" rev-parse HEAD 2>/dev/null || true)"
            echo "opsfactory_git_status:"
            git -C "${OPSFACTORY_SOURCE_DIR}" status --short || true
        fi
        if command -v git >/dev/null 2>&1 && git -C "${PACKAGE_REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "package_git_branch: $(git -C "${PACKAGE_REPO_DIR}" branch --show-current 2>/dev/null || true)"
            echo "package_git_commit: $(git -C "${PACKAGE_REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
            echo "package_git_status:"
            git -C "${PACKAGE_REPO_DIR}" status --short || true
        fi
    } > "${REPORT_FILE}"
}

build_image() {
    docker buildx build \
        --platform linux/amd64 \
        --load \
        --tag "${IMAGE_TAG}" \
        --build-arg "GOOSE_RPM=vendor/goose/${GOOSE_RPM_NAME}" \
        --build-arg "GOOSE_VERSION=${GOOSE_VERSION}" \
        --file "${PACKAGE_REPO_DIR}/docker/offline/Dockerfile" \
        "${STAGING_DIR}"
}

assemble_package() {
    rm -rf "${PACKAGE_DIR}" "${PACKAGE_DIR}.tar.gz"
    mkdir -p "${PACKAGE_DIR}/images" "${PACKAGE_DIR}/scripts"
    sed "s#__IMAGE_TAG__#${IMAGE_TAG}#g" \
        "${PACKAGE_REPO_DIR}/docker/offline/docker-compose.yml.template" > "${PACKAGE_DIR}/docker-compose.yml"
    sed "s#__IMAGE_TAG__#${IMAGE_TAG}#g" \
        "${PACKAGE_REPO_DIR}/docker/offline/README.md" > "${PACKAGE_DIR}/README.md"
    cp "${REPORT_FILE}" "${PACKAGE_DIR}/build-report.txt"
    cp "${PACKAGE_REPO_DIR}/docker/offline/package-scripts/"*.sh "${PACKAGE_DIR}/scripts/"
    if [ -d "${PACKAGE_REPO_DIR}/docker/offline/runtime-overrides" ]; then
        mkdir -p "${PACKAGE_DIR}/runtime-overrides"
        cp "${PACKAGE_REPO_DIR}/docker/offline/runtime-overrides/"* "${PACKAGE_DIR}/runtime-overrides/"
        chmod +x "${PACKAGE_DIR}/runtime-overrides/"*.sh
    fi
    chmod +x "${PACKAGE_DIR}/scripts/"*.sh
    docker image inspect "${IMAGE_TAG}" >/dev/null
    docker save "${IMAGE_TAG}" -o "${IMAGE_TAR}"
    (
        cd "${PACKAGE_DIR}"
        if command -v sha256sum >/dev/null 2>&1; then
            find . -type f ! -name SHA256SUMS.txt -print | sort | xargs sha256sum > SHA256SUMS.txt
        else
            find . -type f ! -name SHA256SUMS.txt -print | sort | xargs shasum -a 256 > SHA256SUMS.txt
        fi
    )
    tar -czf "${PACKAGE_DIR}.tar.gz" -C "${DIST_DIR}" "$(basename "${PACKAGE_DIR}")"
}

run_smoke_test() {
    local tmp
    tmp="$(mktemp -d)"
    tar -xzf "${PACKAGE_DIR}.tar.gz" -C "${tmp}"
    (
        cd "${tmp}/$(basename "${PACKAGE_DIR}")"
        ./scripts/load-image.sh
        ./scripts/start.sh
        ./scripts/status.sh
        ./scripts/stop.sh
    )
    rm -rf "${tmp}"
}

require_cmd docker
require_cmd python3

log "Preparing sanitized staging directory"
prepare_staging
write_report

if [ "${SKIP_DOCKER_BUILD}" = "false" ]; then
    log "Building Docker image ${IMAGE_TAG}"
    build_image
else
    log "Skipping Docker image build"
fi

log "Assembling offline package"
assemble_package

if [ "${SMOKE_TEST}" = "true" ]; then
    log "Running smoke test"
    run_smoke_test
fi

log "Offline package: ${PACKAGE_DIR}.tar.gz"
log "Install on target:"
log "  tar -xzf $(basename "${PACKAGE_DIR}.tar.gz")"
log "  cd $(basename "${PACKAGE_DIR}")"
log "  ./scripts/load-image.sh"
log "  ./scripts/start.sh"
