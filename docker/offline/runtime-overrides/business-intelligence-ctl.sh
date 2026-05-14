#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
ROOT_DIR="$(dirname "${SERVICE_DIR}")"

yaml_val() {
    local key="$1" file="${SERVICE_DIR}/config.yaml"
    [ -f "${file}" ] || return 0
    node -e "const y=require('yaml');const f=require('fs').readFileSync('${file}','utf-8');const c=y.parse(f);const keys='${key}'.split('.');let v=c;for(const k of keys){v=v?.[k]};if(v!=null)process.stdout.write(String(v))" 2>/dev/null || true
}

BI_PORT="${BI_PORT:-$(yaml_val server.port)}"
BI_PORT="${BI_PORT:-8093}"
MVN="${MVN:-mvn}"

if ! command -v "${MVN}" &>/dev/null; then
    for candidate in /tmp/apache-maven-3.9.6/bin/mvn /usr/local/bin/mvn; do
        if [ -x "${candidate}" ]; then
            MVN="${candidate}"
            break
        fi
    done
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $1"; }

LOG_DIR="${SERVICE_DIR}/logs"
PID_FILE="${LOG_DIR}/business-intelligence.pid"
DAEMON_HELPER="${ROOT_DIR}/scripts/lib/service-daemon.sh"

# shellcheck source=/dev/null
source "${DAEMON_HELPER}"

check_port() { daemon_port_has_listener "$1"; }

stop_port() {
    local port=$1 name=$2
    if check_port "${port}"; then
        daemon_stop_listener_port "${port}" "${name}" || true
    fi
}

wait_http_ok() {
    local name="$1" url="$2" attempts="${3:-30}" delay="${4:-1}"
    for ((i=1; i<=attempts; i++)); do
        curl -fsS "${url}" >/dev/null 2>&1 && return 0
        sleep "${delay}"
    done
    log_error "${name} health check failed: ${url}"
    return 1
}

build_service() {
    local jar="${SERVICE_DIR}/target/business-intelligence.jar"
    if [ -f "${jar}" ]; then
        local newest_src
        if [ -d "${SERVICE_DIR}/src" ]; then
            newest_src="$(find "${SERVICE_DIR}/src" -type f \( -name '*.java' -o -name '*.yaml' -o -name '*.yml' \) -newer "${jar}" -print -quit 2>/dev/null)"
        else
            newest_src=""
        fi
        if [ -z "${newest_src}" ] && [ ! "${SERVICE_DIR}/config.yaml" -nt "${jar}" ]; then
            log_info "JAR is up-to-date, skipping build"
            return 0
        fi
    fi

    log_info "Building business-intelligence..."
    cd "${SERVICE_DIR}"
    "${MVN}" package -DskipTests -q || {
        log_error "Maven build failed"
        return 1
    }
}

SERVICE_PID=""

do_startup() {
    local mode="${1:-foreground}"

    if [ "${mode}" = "background" ] && daemon_is_running "${PID_FILE}"; then
        local existing_pid
        existing_pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${BI_PORT}/actuator/health" >/dev/null 2>&1; then
            log_info "business-intelligence already running (PID: ${existing_pid})"
            return 0
        fi
        log_warn "Managed business-intelligence process exists but health check failed; restarting"
        daemon_stop "${PID_FILE}" "business-intelligence" 5 || true
    fi

    if check_port "${BI_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "business-intelligence port ${BI_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${BI_PORT}" "business-intelligence"
    fi

    build_service
    local jar="${SERVICE_DIR}/target/business-intelligence.jar"
    [ -f "${jar}" ] || { log_error "JAR not found: ${jar}"; return 1; }

    log_info "Starting business-intelligence at http://127.0.0.1:${BI_PORT}"
    cd "${SERVICE_DIR}"

    if [ "${mode}" = "background" ]; then
        local log_file="${LOG_DIR}/business-intelligence.log"
        SERVICE_PID="$(daemon_start "${PID_FILE}" "${log_file}" env CONFIG_PATH="${SERVICE_DIR}/config.yaml" java -Dserver.port="${BI_PORT}" -jar "${jar}")"
        if ! kill -0 "${SERVICE_PID}" 2>/dev/null; then
            log_error "Failed to start business-intelligence"
            return 1
        fi
        if ! wait_http_ok "business-intelligence" "http://127.0.0.1:${BI_PORT}/actuator/health" 180 1; then
            daemon_stop "${PID_FILE}" "business-intelligence" 5 || true
            return 1
        fi
        log_info "business-intelligence started (PID: ${SERVICE_PID}, log: ${log_file})"
    else
        exec env CONFIG_PATH="${SERVICE_DIR}/config.yaml" java -Dserver.port="${BI_PORT}" -jar "${jar}"
    fi
}

do_shutdown() {
    daemon_stop "${PID_FILE}" "business-intelligence" 20 || true
    if ! daemon_wait_for_port_release "${BI_PORT}" 20 0.1 && check_port "${BI_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "business-intelligence port ${BI_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${BI_PORT}" "business-intelligence"
    fi
    rm -f "${PID_FILE}" 2>/dev/null || true
}

do_status() {
    if daemon_is_running "${PID_FILE}"; then
        local pid
        pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${BI_PORT}/actuator/health" >/dev/null 2>&1; then
            log_ok "business-intelligence running (http://localhost:${BI_PORT}, PID: ${pid})"
        else
            log_warn "business-intelligence process running (PID: ${pid}) but health check failed"
            return 1
        fi
    elif check_port "${BI_PORT}"; then
        log_warn "business-intelligence port open on ${BI_PORT} but service is unmanaged (missing/stale pidfile)"
        return 1
    else
        log_fail "business-intelligence not running on port ${BI_PORT}"
        return 1
    fi
}

do_restart() {
    do_shutdown
    do_startup "${MODE}"
}

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") <action> [--foreground|--background]

Actions:
  startup     Start business-intelligence
  shutdown    Stop business-intelligence
  status      Check business-intelligence status
  restart     Restart business-intelligence
EOF_USAGE
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
