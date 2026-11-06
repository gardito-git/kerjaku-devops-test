#!/usr/bin/env bash
# run-on-one-host.sh "COMMAND"
# Runs COMMAND via SSM on ONE healthy web server (used for DB migrations, which must run exactly once).
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

CMD=${1:?usage: run-on-one-host.sh COMMAND}

instance=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
  --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | [0].Target.Id' --output text)
[[ -n "$instance" && "$instance" != "None" ]] || die "no healthy instance to run on"

log INFO "running on ${instance}: ${CMD}"
run_on_host "$instance" "$CMD" || die "command failed on ${instance}"
log INFO "done"
