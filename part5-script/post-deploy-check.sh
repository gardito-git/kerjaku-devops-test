#!/usr/bin/env bash
# post-deploy-check.sh — run on a web server right after a deploy.
#
# Checks (in order):
#   1. the `kerjaku` container exists, is running, and has restarted 0 times      → FAIL if not
#   2. GET http://127.0.0.1:3000/health returns 200 (up to 5 tries, 5 s apart)     → FAIL if never
#   3. container is STILL running with 0 restarts after the health checks          → FAIL if not
#      (catches apps that answer once, then crash — e.g. an OOM during cache warm-up)
#   4. disk usage on / > 85 %  or  available memory < 500 MB                        → WARN only
#
# Exit codes (the pipeline rolls back on anything non-zero):
#   0  all checks passed (warnings allowed)
#   1  container check failed
#   2  health check failed
#   3  bad environment (missing tool, docker not reachable) or unexpected script error
#
# All settings can be overridden with environment variables, e.g. HEALTH_ATTEMPTS=10 ./post-deploy-check.sh
# Needs permission to run `docker inspect` (root, or a member of the docker group).

set -Eeuo pipefail

readonly CONTAINER_NAME="${CONTAINER_NAME:-kerjaku}"
readonly HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:3000/health}"
readonly HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-5}"
readonly HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"     # seconds between attempts
readonly CURL_TIMEOUT="${CURL_TIMEOUT:-3}"           # seconds per attempt
readonly DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-85}"
readonly MEM_WARN_MB="${MEM_WARN_MB:-500}"
readonly MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"

readonly EXIT_CONTAINER=1 EXIT_HEALTH=2 EXIT_ENV=3

WARNINGS=0

# ------------------------------------------------------------------ logging
log() {
  # 2026-10-14T14:20:01Z [INFO] post-deploy-check: message
  printf '%s [%s] post-deploy-check: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"
}
info()  { log INFO  "$1"; }
warn()  { log WARN  "$1"; WARNINGS=$((WARNINGS + 1)); }
error() { log ERROR "$1" >&2; }

# Any command that fails unexpectedly (not inside an `if`) lands here instead of dying silently.
on_unexpected_error() {
  local exit_code=$? line=$1
  error "unexpected error (exit ${exit_code}) at line ${line}: ${BASH_COMMAND}"
  exit "$EXIT_ENV"
}
trap 'on_unexpected_error $LINENO' ERR

# ------------------------------------------------------------------ helpers
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

require_tools() {
  local tool missing=0
  for tool in docker curl df awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      error "required tool not found: ${tool}"
      missing=1
    fi
  done
  if (( missing )); then exit "$EXIT_ENV"; fi

  if ! docker info >/dev/null 2>&1; then
    error "cannot talk to the Docker daemon (is it running? are we root / in the docker group?)"
    exit "$EXIT_ENV"
  fi
}

# ------------------------------------------------------------------ 1 + 3: container state
check_container() {
  local stage=$1 inspect status restarts oom_killed

  if ! inspect=$(docker inspect --format '{{.State.Status}} {{.RestartCount}} {{.State.OOMKilled}}' \
                   "$CONTAINER_NAME" 2>/dev/null); then
    error "[${stage}] container '${CONTAINER_NAME}' does not exist"
    return 1
  fi
  read -r status restarts oom_killed <<<"$inspect"

  if [[ "$status" != "running" ]]; then
    error "[${stage}] container '${CONTAINER_NAME}' is '${status}', expected 'running' (OOMKilled=${oom_killed})"
    return 1
  fi
  if ! is_uint "$restarts"; then
    error "[${stage}] could not read restart count (got '${restarts}')"
    return 1
  fi
  if (( restarts != 0 )); then
    error "[${stage}] container '${CONTAINER_NAME}' has restarted ${restarts} time(s) since the deploy (OOMKilled=${oom_killed})"
    return 1
  fi

  info "[${stage}] container '${CONTAINER_NAME}' is running, restart count 0"
}

# ------------------------------------------------------------------ 2: HTTP health
check_health() {
  local attempt http_code

  for (( attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++ )); do
    # curl prints "000" for connection errors/timeouts; `|| true` keeps set -e from aborting the loop.
    http_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
                     --max-time "$CURL_TIMEOUT" "$HEALTH_URL" 2>/dev/null || true)
    http_code=${http_code:-000}

    if [[ "$http_code" == "200" ]]; then
      info "health check ${attempt}/${HEALTH_ATTEMPTS}: ${HEALTH_URL} -> 200 OK"
      return 0
    fi

    if (( attempt < HEALTH_ATTEMPTS )); then
      info "health check ${attempt}/${HEALTH_ATTEMPTS}: ${HEALTH_URL} -> ${http_code}, retrying in ${HEALTH_INTERVAL}s"
      sleep "$HEALTH_INTERVAL"
    else
      error "health check ${attempt}/${HEALTH_ATTEMPTS}: ${HEALTH_URL} -> ${http_code}, giving up"
    fi
  done
  return 1
}

# ------------------------------------------------------------------ 4: host resources (warnings only)
check_disk() {
  local used_percent
  # -P = POSIX output, one line per filesystem, so column 5 is always "Use%".
  used_percent=$(df -P / | awk 'NR == 2 { sub("%", "", $5); print $5 }')

  if ! is_uint "$used_percent"; then
    warn "could not read disk usage for / (got '${used_percent}')"
  elif (( used_percent > DISK_WARN_PERCENT )); then
    warn "disk usage on / is ${used_percent}% (threshold ${DISK_WARN_PERCENT}%)"
  else
    info "disk usage on / is ${used_percent}%"
  fi
}

check_memory() {
  local available_mb
  # MemAvailable (not MemFree) = memory the kernel can hand out without swapping, incl. reclaimable cache.
  available_mb=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' "$MEMINFO_FILE" 2>/dev/null || true)

  if ! is_uint "$available_mb"; then
    warn "could not read MemAvailable from ${MEMINFO_FILE}"
  elif (( available_mb < MEM_WARN_MB )); then
    warn "available memory is ${available_mb} MB (threshold ${MEM_WARN_MB} MB)"
  else
    info "available memory is ${available_mb} MB"
  fi
}

# ------------------------------------------------------------------ main
main() {
  info "starting checks for container '${CONTAINER_NAME}' on $(hostname)"

  for setting in HEALTH_ATTEMPTS HEALTH_INTERVAL CURL_TIMEOUT DISK_WARN_PERCENT MEM_WARN_MB; do
    if ! is_uint "${!setting}"; then
      error "${setting} must be a non-negative integer, got '${!setting}'"
      exit "$EXIT_ENV"
    fi
  done

  require_tools

  check_container "before health check" || exit "$EXIT_CONTAINER"
  check_health                           || exit "$EXIT_HEALTH"
  check_container "after health check"  || exit "$EXIT_CONTAINER"

  check_disk
  check_memory

  info "RESULT: PASS (${WARNINGS} warning(s))"
  exit 0
}

main "$@"
