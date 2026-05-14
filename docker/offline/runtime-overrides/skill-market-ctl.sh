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

SKILL_MARKET_PORT="${SKILL_MARKET_PORT:-$(yaml_val server.port)}"
SKILL_MARKET_PORT="${SKILL_MARKET_PORT:-8095}"
MVN="${MVN:-mvn}"
SKILL_MARKET_LOG_LEVEL="${SKILL_MARKET_LOG_LEVEL:-}"
SKILL_MARKET_LOG_LEVEL_APP="${SKILL_MARKET_LOG_LEVEL_APP:-}"

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
PID_FILE="${LOG_DIR}/skill-market.pid"
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
    local jar="${SERVICE_DIR}/target/skill-market.jar"
    if [ -f "${jar}" ]; then
        local newest_src
        if [ -d "${SERVICE_DIR}/src" ]; then
            newest_src="$(find "${SERVICE_DIR}/src" -type f \( -name '*.java' -o -name '*.yaml' -o -name '*.xml' \) -newer "${jar}" -print -quit 2>/dev/null)"
        else
            newest_src=""
        fi
        if [ -z "${newest_src}" ]; then
            log_info "JAR is up-to-date, skipping build"
            return 0
        fi
    fi

    log_info "Building skill-market..."
    cd "${SERVICE_DIR}"
    "${MVN}" package -DskipTests -q || {
        log_error "Maven build failed"
        return 1
    }
}

do_startup() {
    local mode="${1:-foreground}"

    if [ "${mode}" = "background" ] && daemon_is_running "${PID_FILE}"; then
        local existing_pid
        existing_pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${SKILL_MARKET_PORT}/actuator/health" >/dev/null 2>&1; then
            log_info "skill-market already running (PID: ${existing_pid})"
            return 0
        fi
        log_warn "Managed skill-market process exists but health check failed; restarting"
        daemon_stop "${PID_FILE}" "skill-market" 5 || true
    fi

    if check_port "${SKILL_MARKET_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "skill-market port ${SKILL_MARKET_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${SKILL_MARKET_PORT}" "skill-market"
    fi

    build_service
    local jar="${SERVICE_DIR}/target/skill-market.jar"
    [ -f "${jar}" ] || { log_error "JAR not found: ${jar}"; return 1; }

    log_info "Starting skill-market at http://127.0.0.1:${SKILL_MARKET_PORT}"
    cd "${SERVICE_DIR}"

    local java_opts=(
        "-Dserver.port=${SKILL_MARKET_PORT}"
    )

    if [ -n "${SKILL_MARKET_LOG_LEVEL}" ]; then
        java_opts+=("-Dlogging.level.root=${SKILL_MARKET_LOG_LEVEL}")
    fi
    if [ -n "${SKILL_MARKET_LOG_LEVEL_APP}" ]; then
        java_opts+=("-Dlogging.level.com.huawei.opsfactory.skillmarket=${SKILL_MARKET_LOG_LEVEL_APP}")
    fi

    if [ "${mode}" = "background" ]; then
        local app_log_file="${LOG_DIR}/skill-market.log"
        local console_log_file="${LOG_DIR}/skill-market-console.log"
        java_opts+=("-Dlogging.config=classpath:log4j2-file-only.xml" "-jar" "${jar}")
        local service_pid
        service_pid="$(daemon_start "${PID_FILE}" "${console_log_file}" env java "${java_opts[@]}")"
        if ! kill -0 "${service_pid}" 2>/dev/null; then
            log_error "Failed to start skill-market"
            return 1
        fi
        if ! wait_http_ok "skill-market" "http://127.0.0.1:${SKILL_MARKET_PORT}/actuator/health" 180 1; then
            daemon_stop "${PID_FILE}" "skill-market" 5 || true
            return 1
        fi
        log_info "skill-market started (PID: ${service_pid}, app log: ${app_log_file}, console log: ${console_log_file})"
    else
        java_opts+=("-jar" "${jar}")
        exec env java "${java_opts[@]}"
    fi
}

do_shutdown() {
    daemon_stop "${PID_FILE}" "skill-market" 20 || true
    if ! daemon_wait_for_port_release "${SKILL_MARKET_PORT}" 20 0.1 && check_port "${SKILL_MARKET_PORT}" && ! daemon_is_running "${PID_FILE}"; then
        log_warn "skill-market port ${SKILL_MARKET_PORT} is occupied without a managed pidfile; using legacy port-based stop"
        stop_port "${SKILL_MARKET_PORT}" "skill-market"
    fi
    rm -f "${PID_FILE}" 2>/dev/null || true
}

do_status() {
    if daemon_is_running "${PID_FILE}"; then
        local pid
        pid="$(daemon_read_pid "${PID_FILE}")"
        if curl -fsS "http://127.0.0.1:${SKILL_MARKET_PORT}/actuator/health" >/dev/null 2>&1; then
            log_ok "skill-market running (http://localhost:${SKILL_MARKET_PORT}, PID: ${pid})"
        else
            log_warn "skill-market process running (PID: ${pid}) but health check failed"
            return 1
        fi
    elif check_port "${SKILL_MARKET_PORT}"; then
        log_warn "skill-market port open on ${SKILL_MARKET_PORT} but service is unmanaged (missing/stale pidfile)"
        return 1
    else
        log_fail "skill-market not running on port ${SKILL_MARKET_PORT}"
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
  startup     Start skill-market
  shutdown    Stop skill-market
  status      Check skill-market status
  restart     Restart skill-market
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
