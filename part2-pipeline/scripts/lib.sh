#!/usr/bin/env bash
# Shared helpers for the CI deploy scripts. Sourced, not executed.
# Requires: aws-cli v2, jq. AWS credentials come from the job's OIDC role.

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}"; }
die() { log ERROR "$*"; exit 1; }

: "${TARGET_GROUP_ARN:?TARGET_GROUP_ARN must be set}"

# List instance IDs registered in the target group (any health state).
tg_instances() {
  aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text | tr '\t' '\n' | sort
}

# Count targets currently "healthy".
tg_healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text
}

# Run a shell command on one instance via SSM Run Command (no SSH, no keys, audited in CloudTrail).
# Prints the remote stdout/stderr; returns 0 only if the remote command exited 0.
run_on_host() {
  local instance_id=$1 cmd=$2 command_id status
  command_id=$(aws ssm send-command \
      --instance-ids "$instance_id" \
      --document-name AWS-RunShellScript \
      --comment "GitLab ${CI_PIPELINE_ID:-local}/${CI_JOB_ID:-local}" \
      --timeout-seconds 900 \
      --parameters "$(jq -cn --arg c "$cmd" '{commands: [$c], executionTimeout: ["900"]}')" \
      --query Command.CommandId --output text)

  # `wait` exits non-zero if the command failed; we read the real status afterwards either way.
  aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" 2>/dev/null || true

  status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
             --query Status --output text)
  aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
      --query '[StandardOutputContent, StandardErrorContent]' --output text | sed "s/^/  [$instance_id] /"

  [[ "$status" == "Success" ]]
}
