# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 5 — Automation script (10 pts)

Write a Bash script, `post-deploy-check.sh`, that runs on a web server right after a deploy. It should:
1. Check that the kerjaku container is running and its restart count is 0 (it has not crashed since the deploy).
2. Call http://127.0.0.1:3000/health up to 5 times, 5 seconds apart, and pass only if it returns HTTP 200.
3. Warn if disk usage on / is above 85% or free memory is below 500 MB.
4. Exit with code 0 on success and non-zero on failure, so the pipeline can trigger a rollback.
5. Print clear, timestamped log lines.
We will look at correctness, readability, error handling (set -euo pipefail or equivalent), and whether a pipeline can rely on it.

Script: [`part5-script/post-deploy-check.sh`](part5-script/post-deploy-check.sh). Tests: [`part5-script/test/run-tests.sh`](part5-script/test/run-tests.sh), which runs the script against fake `docker`/`curl`/`df` commands. All 10 cases pass: healthy, healthy after retries, missing container, restarting container, restart count > 0, health never 200, health 500, crash during checks, low disk/memory = warn only, invalid setting.

```bash
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
```

Sample output (failure case):

```
2026-11-05T04:40:16Z [INFO] post-deploy-check: starting checks for container 'kerjaku' on web-1
2026-11-05T04:40:16Z [INFO] post-deploy-check: [before health check] container 'kerjaku' is running, restart count 0
2026-11-05T04:40:17Z [INFO] post-deploy-check: health check 1/5: http://127.0.0.1:3000/health -> 000, retrying in 5s
...
2026-11-05T04:40:38Z [ERROR] post-deploy-check: health check 5/5: http://127.0.0.1:3000/health -> 000, giving up
→ exit 2
```

Design notes, i.e. why a pipeline can rely on it:

- **`set -Eeuo pipefail` + an `ERR` trap:** any unexpected failure exits **3** with the line number and command, so it never "passes by accident". Expected failures are handled explicitly inside `if`s, so `set -e` doesn't kill the retry loop.
- **Distinct exit codes** (1 container, 2 health, 3 environment) tell the pipeline log *why* it failed. Anything non-zero triggers rollback.
- **Container checked twice:** before and after the health checks. A container that answers once and then crashes (like v2.14 during cache warm-up) is caught. It also reports `OOMKilled`, which would have diagnosed Part 4 directly.
- **`curl --max-time`** so a hung app can't hang the pipeline. A connection refused is recorded as `000` and retried. Worst-case runtime is ~5 × (3 s + 5 s) ≈ 40 s.
- **Disk and memory are warnings only**, as specified. `MemAvailable` rather than `MemFree`, because free memory on Linux is normally near 0 thanks to page cache. `df -P` for a stable column layout.
- **Timestamps in UTC ISO-8601** on every line, with stderr for errors, so the pipeline and CloudWatch logs line up.
- All thresholds can be overridden by environment variables and are validated as integers.
