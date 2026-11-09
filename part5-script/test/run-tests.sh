#!/usr/bin/env bash
# Runs post-deploy-check.sh against fake `docker`, `curl` and `df` commands to cover each outcome.
# Usage: bash part5-script/test/run-tests.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../post-deploy-check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fakes are driven by environment variables:
#   FAKE_INSPECT  output of `docker inspect` ("" = container missing)
#   FAKE_INSPECT2 output for the 2nd and later inspect calls (defaults to FAKE_INSPECT)
#   FAKE_CODES    space-separated HTTP codes returned by successive curl calls
#   FAKE_DISK     Use% for /
cat >"$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  inspect)
    n=$(cat "$FAKE_STATE/inspect_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$FAKE_STATE/inspect_calls"
    out=$FAKE_INSPECT; if (( n > 1 )) && [[ -n "${FAKE_INSPECT2:-}" ]]; then out=$FAKE_INSPECT2; fi
    [[ -n "$out" ]] || { echo "Error: No such object" >&2; exit 1; }
    echo "$out" ;;
esac
EOF
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$FAKE_STATE/curl_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$FAKE_STATE/curl_calls"
read -r -a codes <<<"$FAKE_CODES"
code=${codes[$((n - 1))]:-${codes[-1]}}
printf '%s' "$code"
[[ "$code" == "000" ]] && exit 7
exit 0
EOF
cat >"$WORK/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 30000000 1 1 ${FAKE_DISK}% /"
EOF
chmod +x "$WORK/bin/"*

pass=0 fail=0
run_case() {
  local name=$1 expected=$2; shift 2
  local state; state=$(mktemp -d "$WORK/state.XXXX")
  printf 'MemTotal: 8000000 kB\nMemAvailable: %s kB\n' "${MEM_KB:-2048000}" >"$state/meminfo"
  local out code
  out=$(env PATH="$WORK/bin:$PATH" FAKE_STATE="$state" MEMINFO_FILE="$state/meminfo" \
            HEALTH_INTERVAL=0 FAKE_DISK="${FAKE_DISK:-40}" "$@" bash "$SCRIPT" 2>&1)
  code=$?
  if [[ "$code" == "$expected" ]]; then
    pass=$((pass + 1)); printf 'ok   %-45s exit=%s\n' "$name" "$code"
  else
    fail=$((fail + 1)); printf 'FAIL %-45s exit=%s expected=%s\n%s\n' "$name" "$code" "$expected" "$out"
  fi
  [[ -n "${SHOW:-}" ]] && printf '%s\n\n' "$out"
}

SHOW=1 run_case "healthy deploy"                       0 FAKE_INSPECT="running 0 false" FAKE_CODES="200"
run_case "healthy after 3 retries"                    0 FAKE_INSPECT="running 0 false" FAKE_CODES="000 502 200"
run_case "container missing"                          1 FAKE_INSPECT=""                FAKE_CODES="200"
run_case "container restarting (137)"                 1 FAKE_INSPECT="restarting 3 true" FAKE_CODES="200"
run_case "running but already restarted"              1 FAKE_INSPECT="running 2 false" FAKE_CODES="200"
SHOW=1 run_case "health never 200 (5 tries)"          2 FAKE_INSPECT="running 0 false" FAKE_CODES="000"
run_case "health 500"                                 2 FAKE_INSPECT="running 0 false" FAKE_CODES="500"
run_case "crashes during health checks"               1 FAKE_INSPECT="running 0 false" FAKE_INSPECT2="running 1 true" FAKE_CODES="200"
SHOW=1 FAKE_DISK=91 MEM_KB=300000 run_case "low disk + low memory = warn only" 0 FAKE_INSPECT="running 0 false" FAKE_CODES="200"
run_case "bad setting"                                3 FAKE_INSPECT="running 0 false" FAKE_CODES="200" HEALTH_ATTEMPTS=abc

echo "passed: $pass  failed: $fail"
(( fail == 0 ))
