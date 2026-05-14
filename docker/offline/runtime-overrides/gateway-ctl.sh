#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Java Gateway service control (includes goosed agent management)
#
# Usage: ./ctl.sh <action> [--foreground|--background]
#   action: startup | shutdown | status | restart
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
ROOT_DIR="$(dirname "${SERVICE_DIR}")"
GATEWAY_CONFIG_PATH="${GATEWAY_CONFIG_PATH:-${SERVICE_DIR}/config.yaml}"

# --- Configuration (env var > config.yaml > default for operational needs) ---
yaml_path_val() {
    local path="$1" file="${GATEWAY_CONFIG_PATH}"
    [ -f "${file}" ] || return 0
    node -e "const y=require('yaml');const fs=require('fs');const file=process.argv[1];const keys=process.argv[2].split('.');const c=y.parse(fs.readFileSync(file,'utf-8'));let v=c;for(const k of keys){v=v?.[k]};if(v!=null)process.stdout.write(String(v))" \
        "${file}" "${path}" 2>/dev/null || true
}

GATEWAY_HOST="${GATEWAY_HOST:-$(yaml_path_val server.address)}"
GATEWAY_HOST="${GATEWAY_HOST:-0.0.0.0}"
GATEWAY_PORT="${GATEWAY_PORT:-$(yaml_path_val server.port)}"
GATEWAY_PORT="${GATEWAY_PORT:-3000}"
GATEWAY_SECRET_KEY="${GATEWAY_SECRET_KEY:-$(yaml_path_val gateway.secret-key)}"
GATEWAY_SECRET_KEY="${GATEWAY_SECRET_KEY:-test}"
GOOSED_BIN="${GOOSED_BIN:-$(yaml_path_val gateway.goosed-bin)}"
GOOSED_BIN="${GOOSED_BIN:-goosed}"
GOOSE_TLS="${GOOSE_TLS:-$(yaml_path_val gateway.goose-tls)}"
GOOSE_TLS="${GOOSE_TLS:-true}"
GATEWAY_TLS="${GATEWAY_TLS:-$(yaml_path_val server.ssl.enabled)}"
GATEWAY_TLS="${GATEWAY_TLS:-false}"
GATEWAY_KEY_STORE="${GATEWAY_KEY_STORE:-$(yaml_path_val server.ssl.key-store)}"
GATEWAY_KEY_STORE="${GATEWAY_KEY_STORE:-file:.gateway-keystore.p12}"
GATEWAY_KEY_STORE="${GATEWAY_KEY_STORE#file:}"
GATEWAY_KEY_STORE_PASSWORD="${GATEWAY_KEY_STORE_PASSWORD:-$(yaml_path_val server.ssl.key-store-password)}"
GATEWAY_KEY_STORE_PASSWORD="${GATEWAY_KEY_STORE_PASSWORD:-changeit}"

# Gateway TLS scheme + curl options
if [ "${GATEWAY_TLS}" = "true" ]; then
    GATEWAY_SCHEME="https"
    CURL_TLS_OPTS="-k"
else
    GATEWAY_SCHEME="http"
    CURL_TLS_OPTS=""
fi

# Maven path (auto-detect or use env)
MVN="${MVN:-mvn}"
if ! command -v "${MVN}" &>/dev/null; then
    # Try common fallback locations
    for candidate in /tmp/apache-maven-3.9.6/bin/mvn /usr/local/bin/mvn; do
        if [ -x "${candidate}" ]; then
            MVN="${candidate}"
            break
        fi
    done
fi

# --- Logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $1"; }

LOG_DIR="${SERVICE_DIR}/logs"
PID_FILE="${LOG_DIR}/gateway.pid"
GATEWAY_HEALTH_PATH="/gateway/status"
GATEWAY_AGENTS_PATH="/gateway/agents"
DAEMON_HELPER="${ROOT_DIR}/scripts/lib/service-daemon.sh"

# shellcheck source=/dev/null
source "${DAEMON_HELPER}"

# --- Utilities ---
check_port() { daemon_port_has_listener "$1"; }

generate_gateway_api_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'EOF'
import secrets
print(secrets.token_hex(24))
EOF
        return
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-'
        return
    fi
    date +%s | shasum | awk '{print $1}'
}

read_gateway_api_password() {
    if [ ! -t 0 ] || [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        return 2
    fi

    printf "Enter API password for gateway REST interface: " >/dev/tty
    if ! IFS= read -r -s GATEWAY_API_PASSWORD </dev/tty; then
        printf "\n" >/dev/tty
        log_error "Failed to read API password"
        return 1
    fi
    printf "\n" >/dev/tty

    if [ -z "${GATEWAY_API_PASSWORD}" ]; then
        log_error "Password cannot be empty"
        return 1
    fi
}

stop_port() {
    local port=$1 name=$2
    if check_port "${port}"; then
        daemon_stop_listener_port "${port}" "${name}" || true
    fi
}

wait_http_ok() {
    local name="$1" url="$2" headers="${3:-}" attempts="${4:-40}" delay="${5:-1}"
    for ((i=1; i<=attempts; i++)); do
        if [ -n "${headers}" ]; then
            curl -fsS ${CURL_TLS_OPTS} "${url}" -H "${headers}" >/dev/null 2>&1 && return 0
        else
            curl -fsS ${CURL_TLS_OPTS} "${url}" >/dev/null 2>&1 && return 0
        fi
        sleep "${delay}"
    done
    log_error "${name} health check failed: ${url}"
    return 1
}

add_java_opt_from_env() {
    local env_name="$1" property_name="$2"
    if printenv "${env_name}" >/dev/null 2>&1; then
        java_opts+=("-D${property_name}=${!env_name}")
    fi
}

gateway_url() {
    local sk="${GATEWAY_SECRET_KEY}"
    for host in "${GATEWAY_HOST}" "127.0.0.1"; do
        if curl -fsS ${CURL_TLS_OPTS} "${GATEWAY_SCHEME}://${host}:${GATEWAY_PORT}${GATEWAY_HEALTH_PATH}" \
                -H "x-secret-key: ${sk}" >/dev/null 2>&1; then
            echo "${GATEWAY_SCHEME}://${host}:${GATEWAY_PORT}"; return 0
        fi
    done
    for host in "${GATEWAY_HOST}" "127.0.0.1"; do
        local code
        code="$(curl -s ${CURL_TLS_OPTS} -o /dev/null -w "%{http_code}" \
            "${GATEWAY_SCHEME}://${host}:${GATEWAY_PORT}${GATEWAY_HEALTH_PATH}" 2>/dev/null || true)"
        [ "${code}" = "401" ] && { echo "${GATEWAY_SCHEME}://${host}:${GATEWAY_PORT}"; return 0; }
    done
    return 1
}

# --- Build ---
build_gateway() {
    local jar="${SERVICE_DIR}/gateway-service/target/gateway-service.jar"

    # Skip build if JAR exists and no source changes
    if [ -f "${jar}" ]; then
        local jar_time
        jar_time="$(stat -f "%m" "${jar}" 2>/dev/null || stat -c "%Y" "${jar}" 2>/dev/null)"
        local newest_src
        newest_src="$(find "${SERVICE_DIR}" -name "*.java" -newer "${jar}" -print -quit 2>/dev/null)"
        if [ -z "${newest_src}" ]; then
            log_info "JAR is up-to-date, skipping build"
            return 0
        fi
    fi

    log_info "Building Java gateway..."
    cd "${SERVICE_DIR}"
    "${MVN}" package -DskipTests -q || {
        log_error "Maven build failed"
        return 1
    }
    log_info "Build complete"
}

build_node_mcp() {
    local label="$1"
    local mcp_dir="$2"
    local entry="$3"

    if [ ! -f "${mcp_dir}/package.json" ]; then
        return 0
    fi

    local has_build_script
    has_build_script="$(node -e "const fs=require('fs');const pkg=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(pkg.scripts?.build ? 'true' : 'false')" "${mcp_dir}/package.json")"

    local package_stamp="${mcp_dir}/node_modules/.package-lock.json"
    local needs_install="false"
    if [ ! -d "${mcp_dir}/node_modules" ]; then
        needs_install="true"
    elif [ ! -f "${package_stamp}" ]; then
        needs_install="true"
    elif find "${mcp_dir}/package.json" "${mcp_dir}/package-lock.json" -newer "${package_stamp}" 2>/dev/null | grep -q .; then
        needs_install="true"
    fi

    if [ "${has_build_script}" != "true" ] && [ "${needs_install}" != "true" ]; then
        log_info "${label} MCP dependencies are up-to-date, skipping build"
        return 0
    fi

    if [ "${has_build_script}" = "true" ] && [ -f "${entry}" ] && [ ! -d "${mcp_dir}/src" ] && [ "${needs_install}" != "true" ]; then
        log_info "${label} MCP prebuilt dist found, skipping build"
        return 0
    fi

    if [ "${has_build_script}" = "true" ] && [ -f "${entry}" ] && [ -d "${mcp_dir}/node_modules" ] && [ "${needs_install}" != "true" ]; then
        local newest_src
        newest_src="$(find "${mcp_dir}/src" "${mcp_dir}/package.json" "${mcp_dir}/package-lock.json" "${mcp_dir}/tsconfig.json" -newer "${entry}" -print -quit 2>/dev/null)"
        if [ -z "${newest_src}" ]; then
            log_info "${label} MCP is up-to-date, skipping build"
            return 0
        fi
    fi

    log_info "Building ${label} MCP..."
    (
        cd "${mcp_dir}"
        if [ "${needs_install}" = "true" ]; then
            npm install || {
                log_error "${label} MCP npm install failed"
                exit 1
            }
        fi
        if [ "${has_build_script}" = "true" ]; then
            npm run build || {
                log_error "${label} MCP build failed"
                exit 1
            }
        fi
    ) || return 1
    log_info "${label} MCP build complete"
}

build_knowledge_service_mcp() {
    build_node_mcp "Knowledge-Service" \
        "${SERVICE_DIR}/agents/qa-agent/config/mcp/knowledge-service" \
        "${SERVICE_DIR}/agents/qa-agent/config/mcp/knowledge-service/dist/index.js"
}

build_knowledge_cli_mcp() {
    build_node_mcp "Knowledge-Cli" \
        "${SERVICE_DIR}/agents/qa-cli-agent/config/mcp/knowledge-cli" \
        "${SERVICE_DIR}/agents/qa-cli-agent/config/mcp/knowledge-cli/dist/index.js"
}

build_local_tiny_tools_mcp() {
    build_node_mcp "Local-Tiny-Tools" \
        "${SERVICE_DIR}/agents/local-tiny-agent/config/mcp/local-tiny-tools" \
        "${SERVICE_DIR}/agents/local-tiny-agent/config/mcp/local-tiny-tools/dist/index.js"
}

# --- Agents (goosed) helpers ---
shutdown_agents() {
    if pgrep -f goosed >/dev/null 2>&1; then
        log_info "Stopping goosed processes..."
        pkill -f goosed 2>/dev/null || true
        sleep 1
    fi
}

check_agents_configured() {
    local agents_json
    agents_json="$(curl -fsS ${CURL_TLS_OPTS} "${GATEWAY_SCHEME}://127.0.0.1:${GATEWAY_PORT}${GATEWAY_AGENTS_PATH}" \
        -H "x-secret-key: ${GATEWAY_SECRET_KEY}" -H "x-user-id: admin" 2>/dev/null || true)"
    [ -z "${agents_json}" ] && { log_error "Failed to query agents"; return 1; }

    # Parse with lightweight approach (no node dependency)
    local count
    count="$(echo "${agents_json}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('agents',d) if isinstance(d,dict) else d))" 2>/dev/null || echo "0")"

    if [ "${count}" -eq 0 ]; then
        log_error "No agents configured in gateway"
        return 1
    fi

    log_info "Agents configured (${count} total, instances spawn on demand)"
}

status_agents() {
    local base_url
    base_url="$(gateway_url 2>/dev/null)" || true

    if [ -n "${base_url}" ]; then
        local agents_json
        agents_json="$(curl -fsS ${CURL_TLS_OPTS} "${base_url}${GATEWAY_AGENTS_PATH}" \
            -H "x-secret-key: ${GATEWAY_SECRET_KEY}" -H "x-user-id: admin" 2>/dev/null || true)"
        if [ -n "${agents_json}" ]; then
            local count
            count="$(echo "${agents_json}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('agents',d) if isinstance(d,dict) else d))" 2>/dev/null || echo "0")"
            if [ "${count}" -eq 0 ]; then
                log_fail "No agents configured in gateway"
                return 1
            else
                log_ok "Agents configured (${count} total)"
            fi
        else
            log_fail "Failed to query ${GATEWAY_AGENTS_PATH}"
            return 1
        fi
    else
        log_warn "Gateway unreachable - cannot check agents"
        return 1
    fi
}

# --- Gateway actions ---
GATEWAY_PID=""

do_startup() {
    local mode="${1:-foreground}"

    cd "${SERVICE_DIR}"

    if [ "${mode}" = "background" ] && daemon_is_running "${PID_FILE}"; then
        local existing_pid
        existing_pid="$(daemon_read_pid "${PID_FILE}")"
        if gateway_url >/dev/null 2>&1; then
            log_info "Gateway already running (PID: ${existing_pid})"
            check_agents_configured || true
            return 0
        fi
        log_warn "Managed gateway process exists but health check failed; restarting"
        daemon_stop "${PID_FILE}" "gateway" 5 || true
    fi

    shutdown_agents
    if check_port "${GATEWAY_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "Gateway port ${GATEWAY_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${GATEWAY_PORT}" "gateway"
    fi

    build_gateway
    build_knowledge_service_mcp
    build_knowledge_cli_mcp
    build_local_tiny_tools_mcp

    local jar="${SERVICE_DIR}/gateway-service/target/gateway-service.jar"
    local lib_dir="${SERVICE_DIR}/gateway-service/target/lib"

    if [ ! -f "${jar}" ]; then
        log_error "JAR not found: ${jar}"
        return 1
    fi

    # Auto-generate self-signed keystore for TLS if needed
    local gateway_key_alias=""
    if [ "${GATEWAY_TLS}" = "true" ]; then
        if [ -z "${GATEWAY_KEY_STORE}" ]; then
            GATEWAY_KEY_STORE="${SERVICE_DIR}/.gateway-keystore.p12"
            gateway_key_alias="gateway"
        else
            # Resolve relative path against SERVICE_DIR
            case "${GATEWAY_KEY_STORE}" in
                /*) ;; # already absolute
                *)  GATEWAY_KEY_STORE="${SERVICE_DIR}/${GATEWAY_KEY_STORE}" ;;
            esac
        fi
        if [ ! -f "${GATEWAY_KEY_STORE}" ]; then
            log_info "Generating self-signed TLS certificate..."
            keytool -genkeypair -alias gateway -keyalg RSA -keysize 2048 \
                -storetype PKCS12 -keystore "${GATEWAY_KEY_STORE}" \
                -storepass "${GATEWAY_KEY_STORE_PASSWORD}" \
                -validity 3650 -dname "CN=localhost" \
                -ext "SAN=dns:localhost,dns:host.docker.internal,ip:127.0.0.1,ip:0.0.0.0" 2>/dev/null
            log_info "Certificate saved to ${GATEWAY_KEY_STORE}"
        fi
        # Auto-detect alias from existing keystore when not auto-generated
        if [ -z "${gateway_key_alias}" ] && [ -f "${GATEWAY_KEY_STORE}" ]; then
            gateway_key_alias=$(keytool -list -keystore "${GATEWAY_KEY_STORE}" \
                -storepass "${GATEWAY_KEY_STORE_PASSWORD}" -storetype PKCS12 2>/dev/null \
                | awk -F, '/PrivateKeyEntry/ {print $1; exit}' | xargs)
        fi
        # Export certificate as PEM for Docker containers (OnlyOffice etc.)
        local gateway_cert_pem="${GATEWAY_KEY_STORE%.p12}.pem"
        if [ ! -f "${gateway_cert_pem}" ] || [ "${GATEWAY_KEY_STORE}" -nt "${gateway_cert_pem}" ]; then
            keytool -exportcert -alias "${gateway_key_alias:-1}" -keystore "${GATEWAY_KEY_STORE}" \
                -storepass "${GATEWAY_KEY_STORE_PASSWORD}" -rfc > "${gateway_cert_pem}" 2>/dev/null || true
        fi
    fi

    if [ -z "${GATEWAY_API_PASSWORD:-}" ]; then
        log_info "GATEWAY_API_PASSWORD is empty"
    else
        log_info "Using provided GATEWAY_API_PASSWORD"
    fi

    log_info "Starting gateway at ${GATEWAY_SCHEME}://${GATEWAY_HOST}:${GATEWAY_PORT}"
    log_info "[gooseTls config] effective=${GOOSE_TLS} (source: env override or config.yaml)"

    # Build Java command — config.yaml is loaded by Spring, env vars only provide explicit overrides
    local java_cmd="java"
    local java_opts=(
        "-Dloader.path=${lib_dir}"
    )
    if [ -n "${GATEWAY_API_PASSWORD:-}" ]; then
        java_opts+=("-Dgateway.api.password=${GATEWAY_API_PASSWORD}")
    fi

    add_java_opt_from_env GATEWAY_PORT server.port
    add_java_opt_from_env GATEWAY_HOST server.address
    add_java_opt_from_env GATEWAY_SECRET_KEY gateway.secret-key
    add_java_opt_from_env CORS_ORIGIN gateway.cors-origin
    add_java_opt_from_env GOOSED_BIN gateway.goosed-bin
    add_java_opt_from_env GOOSE_TLS gateway.goose-tls
    add_java_opt_from_env PROJECT_ROOT gateway.paths.project-root
    add_java_opt_from_env AGENTS_DIR gateway.paths.agents-dir
    add_java_opt_from_env USERS_DIR gateway.paths.users-dir
    add_java_opt_from_env IDLE_TIMEOUT_MINUTES gateway.idle.timeout-minutes
    add_java_opt_from_env IDLE_CHECK_INTERVAL gateway.idle.check-interval-ms
    add_java_opt_from_env SSE_FIRST_BYTE_TIMEOUT gateway.sse.first-byte-timeout-sec
    add_java_opt_from_env SSE_IDLE_TIMEOUT gateway.sse.idle-timeout-sec
    add_java_opt_from_env SSE_MAX_DURATION gateway.sse.max-duration-sec
    add_java_opt_from_env MAX_FILE_SIZE_MB gateway.upload.max-file-size-mb
    add_java_opt_from_env MAX_IMAGE_SIZE_MB gateway.upload.max-image-size-mb
    add_java_opt_from_env MAX_INSTANCES_PER_USER gateway.limits.max-instances-per-user
    add_java_opt_from_env MAX_INSTANCES_GLOBAL gateway.limits.max-instances-global
    add_java_opt_from_env PREWARM_ENABLED gateway.prewarm.enabled
    add_java_opt_from_env PREWARM_DEFAULT_AGENT_ID gateway.prewarm.default-agent-id
    add_java_opt_from_env LANGFUSE_HOST gateway.langfuse.host
    add_java_opt_from_env LANGFUSE_PUBLIC_KEY gateway.langfuse.public-key
    add_java_opt_from_env LANGFUSE_SECRET_KEY gateway.langfuse.secret-key
    add_java_opt_from_env OFFICE_PREVIEW_ENABLED gateway.office-preview.enabled
    add_java_opt_from_env ONLYOFFICE_URL gateway.office-preview.onlyoffice-url
    add_java_opt_from_env FILE_BASE_URL gateway.office-preview.file-base-url

    # Gateway TLS: inject Spring Boot SSL properties
    if [ "${GATEWAY_TLS}" = "true" ]; then
        java_opts+=(
            "-Dserver.ssl.enabled=true"
        )
        if printenv GATEWAY_KEY_STORE >/dev/null 2>&1; then
            java_opts+=("-Dserver.ssl.key-store=file:${GATEWAY_KEY_STORE}")
        fi
        if printenv GATEWAY_KEY_STORE_PASSWORD >/dev/null 2>&1; then
            java_opts+=("-Dserver.ssl.key-store-password=${GATEWAY_KEY_STORE_PASSWORD}")
        fi
        if printenv GATEWAY_KEY_STORE_TYPE >/dev/null 2>&1; then
            java_opts+=("-Dserver.ssl.key-store-type=${GATEWAY_KEY_STORE_TYPE}")
        fi
        if [ -n "${gateway_key_alias}" ]; then
            java_opts+=("-Dserver.ssl.key-alias=${gateway_key_alias}")
        fi
    fi

    if [ "${mode}" = "background" ]; then
        java_opts+=("-Dgateway.console.threshold=OFF")
    else
        java_opts+=("-Dgateway.console.threshold=INFO")
    fi

    java_opts+=("-DGATEWAY_CONFIG_PATH=${GATEWAY_CONFIG_PATH}")
    java_opts+=("-jar" "${jar}")

    if [ "${mode}" = "background" ]; then
        local console_log="${LOG_DIR}/gateway-stdout-stderr.log"
        local app_log="${LOG_DIR}/gateway.log"
        GATEWAY_PID="$(daemon_start "${PID_FILE}" "${console_log}" env GATEWAY_CONFIG_PATH="${GATEWAY_CONFIG_PATH}" "${java_cmd}" "${java_opts[@]}")"
        if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
            log_error "Failed to start gateway"
            return 1
        fi
        if ! wait_http_ok "Gateway" "${GATEWAY_SCHEME}://127.0.0.1:${GATEWAY_PORT}${GATEWAY_HEALTH_PATH}" \
                "x-secret-key: ${GATEWAY_SECRET_KEY}" 180 1; then
            log_error "Gateway failed to become healthy. Check logs: ${app_log} and ${console_log}"
            daemon_stop "${PID_FILE}" "gateway" 5 || true
            return 1
        fi
        log_info "Gateway started (PID: ${GATEWAY_PID}, log: ${app_log})"
        check_agents_configured || true
    else
        exec env GATEWAY_CONFIG_PATH="${GATEWAY_CONFIG_PATH}" ${java_cmd} "${java_opts[@]}"
    fi
}

do_shutdown() {
    daemon_stop "${PID_FILE}" "gateway" 20 || true
    if ! daemon_wait_for_port_release "${GATEWAY_PORT}" 20 0.1 && check_port "${GATEWAY_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "Gateway port ${GATEWAY_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${GATEWAY_PORT}" "gateway"
    fi
    rm -f "${PID_FILE}" 2>/dev/null || true
    shutdown_agents
}

do_status() {
    local has_fail=0
    if daemon_is_running "${PID_FILE}"; then
        local pid
        pid="$(daemon_read_pid "${PID_FILE}")"
        if gateway_url >/dev/null 2>&1; then
            log_ok "Gateway running (${GATEWAY_SCHEME}://localhost:${GATEWAY_PORT}, PID: ${pid})"
        else
            log_fail "Gateway process running (PID: ${pid}) but ${GATEWAY_HEALTH_PATH} check failed"
            has_fail=1
        fi
    elif check_port "${GATEWAY_PORT}"; then
        log_warn "Gateway port open on ${GATEWAY_PORT} but service is unmanaged (missing/stale pidfile)"
        has_fail=1
    else
        log_fail "Gateway not running on port ${GATEWAY_PORT}"
        has_fail=1
    fi
    status_agents || has_fail=1
    return "${has_fail}"
}

do_restart() {
    do_shutdown
    do_startup "${MODE}"
}

# --- Main ---
usage() {
    cat <<EOF
Usage: $(basename "$0") <action> [--foreground|--background]

Actions:
  startup     Build and start Java gateway (goosed agents spawn on demand)
  shutdown    Stop gateway and all goosed processes
  status      Check gateway and agent status
  restart     Restart gateway
EOF
    exit 1
}

ACTION="${1:-}"
[ -z "${ACTION}" ] && usage
shift

MODE="background"
for arg in "$@"; do
    case "${arg}" in
        --background) MODE="background" ;;
        --foreground) MODE="foreground" ;;
    esac
done

case "${ACTION}" in
    startup)  do_startup "${MODE}" ;;
    shutdown) do_shutdown ;;
    status)   do_status ;;
    restart)  do_restart ;;
    -h|--help|help) usage ;;
    *) log_error "Unknown action: ${ACTION}"; usage ;;
esac
