# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 3 - Infrastructure as code (15 points)

A developer wrote this Terraform to move the web servers into an Auto Scaling Group. It is
waiting for your review.

---
### File E - web.tf
```hcl
resource "aws_security_group" "web" {
  name   = "web-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "web" {
  name_prefix   = "kerjaku-web-"
  image_id      = "ami-0abc1234def567890"
  instance_type = "t3.medium"
  key_name      = "shared-team-key"
  vpc_security_group_ids = [aws_security_group.web.id]
  
  user_data = base64encode(<<-EOF
    #!/bin/bash
    export AWS_ACCESS_KEY_ID=AKIAEXAMPLE123456
    export AWS_SECRET_ACCESS_KEY=wJalrEXAMPLEKEY
    aws s3 cp s3://kerjaku-config/.env /var/www/kerjaku/.env
    docker run -d -p 3000:3000 kerjaku-app:latest
  EOF
  )
}

resource "aws_autoscaling_group" "web" {
  min_size            = 1
  max_size            = 10
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_a]
  health_check_type   = "EC2"
  target_group_arns   = [var.alb_target_group_arn]
  
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
}
```
The team keeps Terraform state in a local terraform.tfstate file committed to Git.

### Questions
1. Write your code review: list each issue, its risk, and the fix. (8 pts)
2. Rewrite the security group and Auto Scaling Group blocks the way you would merge them. (4 pts)
3. What is wrong with how the team stores Terraform state, and what would you set up instead? (3 pts)

## Answer
### 1. Write your code review: list each issue, its risk, and the fix. (8 pts)
| # | Issue | Risk | Fix |
|---|---|---|---|
| 1 | **Hard-coded `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in `user_data`** | **Critical.** The key is now in Git, in Terraform state, in the launch template (readable by anyone with `ec2:DescribeLaunchTemplateVersions`) and in instance user-data (readable from IMDS by *any process on the box*, including via SSRF). Long-lived, unrotated, probably over-privileged. | **Deactivate and rotate the key today**, and check CloudTrail for its use. Use an **IAM instance profile** with least-privilege permissions. |
| 2 | **SG ingress `0-65535` from `0.0.0.0/0`** | **Critical.** Every port on every instance is open to the internet: SSH, :3000, the Docker API if ever enabled, node debug ports. | Ingress **only port 80 from the ALB security group**. No SSH (use SSM Session Manager). |
| 3 | **`docker run … kerjaku-app:latest` with a local image name** | **Critical.** A fresh instance has no image called `kerjaku-app:latest` (it was only ever built locally on the old servers), so **every instance the ASG launches will fail to start the app**. The `.env` it just downloaded isn't even passed (`--env-file` missing). No restart policy, `0.0.0.0:3000`, and `latest` means no version control. | Pull a specific `ECR:<sha>` (from SSM Parameter `/kerjaku/prod/current_image`) and start it with the same script the pipeline uses (`kerjaku-host-deploy`). |
| 4 | **`vpc_zone_identifier = [var.public_subnet_a]`** | **High.** One AZ means an AZ outage takes the whole site down. A public subnet means instances may get public IPs and sit directly on the internet. | **Private subnets in ≥ 2 AZs.** Only the ALB is public. |
| 5 | **`min_size = 1`, `desired_capacity = 1`** | **High.** Less capacity than today (2), a single point of failure, and any instance refresh or replacement is an outage. | `min_size = 2`. Don't set `desired_capacity` (or `ignore_changes`) so `terraform apply` doesn't fight the autoscaler. |
| 6 | **`health_check_type = "EC2"`** | **High.** The ASG only replaces instances whose *VM* fails. An instance whose app is crash-looping (Part 4) stays in service forever. | `health_check_type = "ELB"` + `health_check_grace_period = 180`, with the ALB health check on `/health`. |
| 7 | **`key_name = "shared-team-key"`** | **High.** One private key shared by everyone: no attribution, and it can't be revoked when someone leaves (Part 6). | Remove it. Use **SSM Session Manager** (IAM-based, per user, logged). |
| 8 | **IMDSv1 allowed** (no `metadata_options`) | **High.** An SSRF bug in the app can read instance-role credentials. | `http_tokens = "required"` (IMDSv2), `hop_limit = 2` for containers. |
| 9 | **`.env` file copied from S3** | **Medium.** Secrets in a file in a bucket (versioned copies, broad `s3:GetObject`), no rotation, no audit per secret. | Secrets Manager + instance role (Part 6). |
| 10 | **`version = "$Latest"`** with no rollout strategy | **Medium.** A launch template change only affects *new* instances, silently. The fleet ends up running mixed versions with no controlled rollout or rollback. | `version = aws_launch_template.web.latest_version` + an **`instance_refresh`** block (rolling, `min_healthy_percentage = 100`, `auto_rollback = true`). |
| 11 | **`max_size = 10` but no scaling policy** | **Medium.** It never scales. `max_size` is meaningless. | Target-tracking policy (CPU ~55% or ALB requests per target). |
| 12 | **Egress all ports/protocols to `0.0.0.0/0`** | **Medium.** A compromised box can talk to anything (exfiltration, crypto-mining pools). | 443 out (AWS APIs, third-party APIs) and 3306 to the RDS SG only. |
| 13 | **Hard-coded AMI ID**, no explanation of what's on it | **Medium.** Nobody knows what's in it or how to rebuild it. It may lack Docker. | Golden AMI built by **Packer** in CI (Docker, compose, SSM + CloudWatch agents, deploy scripts), passed in as a validated variable. |
| 14 | **`t3.medium` (4 GB)** | **Medium.** This is the size that just OOMed in Part 4. t3 is also burstable, so CPU credits can run out under sustained load. | `t3.large` (or non-burstable `m6i.large`), the same for every instance. |
| 15 | **SG with fixed `name`**, no `create_before_destroy` | **Low.** Any change that forces replacement fails ("name already exists") or detaches the SG from running instances. | `name_prefix` + `create_before_destroy`. |
| 16 | **No EBS encryption, no detailed monitoring, no tags**; no provider/version pinning | **Low.** Compliance gaps (CV data = PII), no cost allocation, and provider upgrades can change behaviour. | `encrypted = true`, gp3, tags via `default_tags`, `required_providers` pinned. |
| 17 | **State committed to Git** (see 3.3) | **Critical.** | S3 backend with locking. |

### 2. Rewrite the security group and Auto Scaling Group blocks the way you would merge them. (4 pts)
Full file (also includes the fixed launch template, IAM role and scaling policy): [`part3-terraform/web.tf`](part3-terraform/web.tf). `terraform init -backend=false && terraform validate` passes.

```hcl
resource "aws_security_group" "web" {
  name_prefix = "kerjaku-web-"
  description = "KerjaKu web servers: HTTP from ALB only"
  vpc_id      = var.vpc_id
  tags        = { Name = "kerjaku-web" }
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "web_http_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "Nginx from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "web_https_out" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS to AWS APIs and third-party APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_mysql_out" {
  security_group_id            = aws_security_group.web.id
  description                  = "MySQL to RDS only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.rds_security_group_id
}

resource "aws_autoscaling_group" "web" {
  name_prefix         = "kerjaku-web-"
  min_size            = 2
  max_size            = 6
  vpc_zone_identifier = var.private_subnet_ids        # >= 2 AZs, validated in variables.tf
  target_group_arns   = [var.alb_target_group_arn]
  # desired_capacity not set: starts at min_size, then the scaling policy owns it

  health_check_type         = "ELB"
  health_check_grace_period = 180
  default_instance_warmup   = 180
  wait_for_capacity_timeout = "15m"

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      instance_warmup        = 180
      auto_rollback          = true
    }
  }

  enabled_metrics = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupPendingInstances",
                     "GroupTerminatingInstances", "GroupTotalInstances"]

  tag {
    key                 = "Name"
    value               = "kerjaku-web"
    propagate_at_launch = true
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_policy" "web_cpu" {
  name                   = "kerjaku-web-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 55
  }
}
```

The ALB security group must also allow egress to the web SG on port 80, and the RDS SG must allow 3306 from the web SG. Both live outside this file.

### 3. What is wrong with how the team stores Terraform state, and what would you set up instead? (3 pts)
**What's wrong:**

- **Secrets in plain text.** State stores every attribute, including the hard-coded access key in `user_data`, any generated DB passwords and private keys. Everyone with repo access (and every clone, fork and laptop, forever, via Git history) has them.
- **No locking.** Two people running `apply` at once both write state, and one overwrites the other, giving a corrupted or lost state.
- **Stale state.** If someone applies without pulling first, Terraform plans against an old view of the world and can **destroy or duplicate** real resources. Merge conflicts in a JSON state file are effectively unresolvable.
- **No reliable history or recovery** beyond Git, and anyone can edit it.

**What I'd set up:**

1. **S3 backend:** a dedicated bucket `kerjaku-terraform-state` with **versioning** (recover from bad writes), **SSE-KMS** encryption, **Block Public Access**, TLS-only bucket policy, and access limited to the CI apply role + 1–2 admins (break-glass). Optionally a separate AWS account for state.
2. **Locking:** S3-native locking (`use_lockfile = true`, Terraform ≥ 1.10), or a DynamoDB lock table on older versions.
3. **One state per environment/component** (`prod/web`, `prod/network`, `staging/web`) to limit blast radius.
4. **Migration:** add the backend block, run `terraform init -migrate-state`, check `terraform plan` shows no changes, then `git rm --cached terraform.tfstate*` and add `*.tfstate*` and `.terraform/` to `.gitignore`. **Purge the files from Git history** (`git filter-repo`) and **rotate every secret that was in them**. Removing them from history doesn't un-leak them.
5. **Workflow:** `terraform plan` runs in the MR pipeline and posts the plan. `apply` runs only from `main` in CI with an OIDC role. Humans don't apply from laptops.

Config: [`part3-terraform/versions.tf`](part3-terraform/versions.tf).