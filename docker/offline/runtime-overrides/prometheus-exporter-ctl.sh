#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
ROOT_DIR="$(dirname "${SERVICE_DIR}")"

yaml_val() {
    local key="$1" file="${SERVICE_DIR}/config.yaml"
    [ -f "${file}" ] || return 0
    awk -F': ' -v k="${key}" '$1==k {print $2}' "${file}" | head -n1 | sed 's/^["'"'"']//;s/["'"'"']$//'
}

EXPORTER_PORT="${EXPORTER_PORT:-$(yaml_val port)}"
EXPORTER_PORT="${EXPORTER_PORT:-9091}"
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
PID_FILE="${LOG_DIR}/prometheus-exporter.pid"
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
    local name="$1" url="$2" attempts="${3:-20}" delay="${4:-1}"
    for ((i=1; i<=attempts; i++)); do
        curl -fsS "${url}" >/dev/null 2>&1 && return 0
        sleep "${delay}"
    done
    log_error "${name} health check failed: ${url}"
    return 1
}

build_exporter() {
    local jar="${SERVICE_DIR}/target/prometheus-exporter.jar"
    if [ -f "${jar}" ]; then
        local newest_src
        if [ -d "${SERVICE_DIR}/src" ]; then
            newest_src="$(find "${SERVICE_DIR}/src" -name "*.java" -newer "${jar}" -print -quit 2>/dev/null)"
        else
            newest_src=""
        fi
        if [ -z "${newest_src}" ]; then
            log_info "JAR is up-to-date, skipping build"
            return 0
        fi
    fi

    log_info "Building Prometheus Exporter..."
    cd "${SERVICE_DIR}"
    "${MVN}" package -DskipTests -q || {
      log_error "Maven build failed"
      return 1
    }
}

EXPORTER_PID=""

do_startup() {
    local mode="${1:-foreground}"

    if [ "${mode}" = "background" ] && daemon_is_running "${PID_FILE}"; then
        local existing_pid
        existing_pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/health" >/dev/null 2>&1; then
            log_info "Exporter already running (PID: ${existing_pid})"
            return 0
        fi
        log_warn "Managed exporter process exists but health check failed; restarting"
        daemon_stop "${PID_FILE}" "exporter" 5 || true
    fi

    if check_port "${EXPORTER_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "Exporter port ${EXPORTER_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${EXPORTER_PORT}" "exporter"
    fi

    build_exporter
    local jar="${SERVICE_DIR}/target/prometheus-exporter.jar"
    [ -f "${jar}" ] || { log_error "JAR not found: ${jar}"; return 1; }

    log_info "Starting Prometheus Exporter at http://127.0.0.1:${EXPORTER_PORT}/metrics"
    cd "${SERVICE_DIR}"

    if [ "${mode}" = "background" ]; then
        local log_file="${LOG_DIR}/exporter.log"
        EXPORTER_PID="$(daemon_start "${PID_FILE}" "${log_file}" env CONFIG_PATH="${SERVICE_DIR}/config.yaml" \
            java -Dserver.port="${EXPORTER_PORT}" -jar "${jar}")"
        if ! kill -0 "${EXPORTER_PID}" 2>/dev/null; then
            log_error "Failed to start exporter"
            return 1
        fi
        if ! wait_http_ok "Exporter" "http://127.0.0.1:${EXPORTER_PORT}/health" 120 1; then
            daemon_stop "${PID_FILE}" "exporter" 5 || true
            return 1
        fi
        log_info "Exporter started (PID: ${EXPORTER_PID}, log: ${log_file})"
    else
        exec env CONFIG_PATH="${SERVICE_DIR}/config.yaml" java -Dserver.port="${EXPORTER_PORT}" -jar "${jar}"
    fi
}

do_shutdown() {
    daemon_stop "${PID_FILE}" "exporter" 20 || true
    if ! daemon_wait_for_port_release "${EXPORTER_PORT}" 20 0.1 && check_port "${EXPORTER_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "Exporter port ${EXPORTER_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${EXPORTER_PORT}" "exporter"
    fi
    rm -f "${PID_FILE}" 2>/dev/null || true
}

do_status() {
    if daemon_is_running "${PID_FILE}"; then
        local pid
        pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/health" >/dev/null 2>&1; then
            log_ok "Exporter running (http://localhost:${EXPORTER_PORT}/metrics, PID: ${pid})"
        else
            log_warn "Exporter process running (PID: ${pid}) but health check failed"
            return 1
        fi
    elif check_port "${EXPORTER_PORT}"; then
        log_warn "Exporter port open on ${EXPORTER_PORT} but service is unmanaged (missing/stale pidfile)"
        return 1
    else
        log_fail "Exporter not running on port ${EXPORTER_PORT}"
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
  startup     Start Prometheus Exporter
  shutdown    Stop exporter
  status      Check exporter status
  restart     Restart exporter
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
