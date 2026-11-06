#!/usr/bin/env bash
# rolling-deploy.sh IMAGE
#
# Zero-downtime rolling deploy behind the ALB, one server at a time:
#   for each target:  deregister → wait for connection draining → deploy via SSM
#                     → post-deploy-check on the host → register → wait until ALB says "healthy"
# If any host fails, that host is rolled back to the image it was running, put back in service,
# and the script stops with a non-zero exit (the remaining hosts are untouched).
#
# Env: TARGET_GROUP_ARN (required), RECORD_PREVIOUS (default true; the rollback job sets false)
#
# Prerequisite: target group deregistration_delay = 30s (the AWS default of 300s would make
# each host take 5+ minutes and break the "rollback in < 5 minutes" goal).

set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
trap 'log ERROR "unexpected failure at line $LINENO"' ERR

IMAGE=${1:?usage: rolling-deploy.sh IMAGE}
RECORD_PREVIOUS=${RECORD_PREVIOUS:-true}
PORT=80

mapfile -t INSTANCES < <(tg_instances)
(( ${#INSTANCES[@]} > 0 )) || die "no instances in target group"

# Safety: never start a rolling deploy if we are already degraded — taking one host out would
# leave nothing serving traffic.
healthy=$(tg_healthy_count)
if (( healthy < ${#INSTANCES[@]} || healthy < 2 )); then
  die "only ${healthy}/${#INSTANCES[@]} targets healthy; refusing to start a rolling deploy (fix the fleet first)"
fi

current_image=$(aws ssm get-parameter --name /kerjaku/prod/current_image --query Parameter.Value --output text 2>/dev/null || echo "none")
log INFO "deploying ${IMAGE} (currently ${current_image}) to ${#INSTANCES[@]} hosts: ${INSTANCES[*]}"

for id in "${INSTANCES[@]}"; do
  target="Id=${id},Port=${PORT}"

  log INFO "[$id] removing from load balancer and draining connections"
  aws elbv2 deregister-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"
  aws elbv2 wait target-deregistered --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"

  log INFO "[$id] deploying"
  if ! run_on_host "$id" "/usr/local/bin/kerjaku-host-deploy deploy '${IMAGE}'"; then
    log ERROR "[$id] deploy or post-deploy check FAILED — rolling this host back"
    run_on_host "$id" "/usr/local/bin/kerjaku-host-deploy rollback" || log ERROR "[$id] host rollback failed too, needs a human"
    aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"
    aws elbv2 wait target-in-service --target-group-arn "$TARGET_GROUP_ARN" --targets "$target" || true
    die "release ${IMAGE} aborted on ${id}; other hosts are still on the previous version"
  fi

  log INFO "[$id] adding back to load balancer"
  aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"
  # Waits until the ALB health check (/health → app) passes. Fails after ~10 min.
  if ! aws elbv2 wait target-in-service --target-group-arn "$TARGET_GROUP_ARN" --targets "$target"; then
    die "[$id] never became healthy in the ALB"
  fi
  log INFO "[$id] healthy in ALB"
done

# Record what is running, so new ASG instances and the rollback job know which image to use.
if [[ "$RECORD_PREVIOUS" == "true" && "$current_image" != "none" && "$current_image" != "$IMAGE" ]]; then
  aws ssm put-parameter --name /kerjaku/prod/previous_image --value "$current_image" --type String --overwrite >/dev/null
fi
aws ssm put-parameter --name /kerjaku/prod/current_image --value "$IMAGE" --type String --overwrite >/dev/null
log INFO "release complete: ${IMAGE}"
