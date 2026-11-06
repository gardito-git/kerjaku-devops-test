# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 2 - Deployment pipeline (25 points)

### File D1 - .gitlab-ci.yml
```yaml
stages: [deploy]

  deploy:
    stage: deploy
    image: alpine:latest
    script:
      - apk add --no-cache openssh-client
      - echo "$PROD_SSH_KEY" > key.pem && chmod 600 key.pem
      - |
        for host in 10.0.1.11 10.0.1.12; do
          ssh -o StrictHostKeyChecking=no -i key.pem root@$host "
          cd /var/www/kerjaku &&
          git pull origin main &&
          npm install &&
          npm run migrate &&
          docker build -t kerjaku-app:latest . &&
          docker stop kerjaku && docker rm kerjaku &&
          docker run -d --name kerjaku -p 3000:3000 kerjaku-app:latest
        "
        done
      - echo "Deployed by $GITLAB_USER_LOGIN, DB=$DB_PASSWORD"
```

### File D2 - /etc/gitlab-runner/config.toml
```yaml
concurrent = 4

[[runners]]
name = "web-1-runner"
  url = "https://gitlab.kerjaku.example.com"
  token = "glrt-EXAMPLEa1b2c3d4"
  executor = "docker"
  [runners.docker]
    image = "alpine:latest"
    privileged = true
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", 
"/root/.ssh:/root/.ssh:ro", "/cache"]
```
### Runner and variable facts:
- The runner is installed on web-1 , one of the two production web servers.
- It is registered as an instance runner, so every project on the GitLab server can use it.
- It is set to run untagged jobs and is not limited to protected branches.
- CI/CD variables `PROD_SSH_KEY` and `DB_PASSWORD` are not marked Protected or Masked
### Question
1. List the problems with File D1. For each, explain what could go wrong in production. (6pts)
2. Review the runner setup (File D2 and the facts). List the risks, then describe how you would set up GitLab Runners for KerjaKu: where they run, which executor, how they get AWS access, how build jobs are kept apart from production deploys, and which settings you would use for tags, protected branches and variables. (6 pts)
3. Design a better deployment process for KerjaKu. It must cover:
  - zero-downtime releases across both servers behind the ALB
  - a one-step rollback to the previous version, in under 5 minutes
  - where images are built and stored, and how they are tagged
  - how database migrations run safely (including a migration that would break the old version still running)
  - how secrets reach the app
A diagram or numbered steps is fine. Write the new `.gitlab-ci.yml` , or detailed pseudo-YAML. (10 pts)
4. Developers want to deploy on their own, any time. What guardrails would you put in place so they can do this safely? Name at least three. (3 pts)

## Answer
### 1. List the problems with File D1. For each, explain what could go wrong in production. (6pts)
| # | Problem | What can go wrong in production |
|---|---|---|
| 1 | **No `rules`/`only`: every push to every branch deploys to production.** | A developer pushes a half-finished feature branch and it goes live. Two people pushing different branches overwrite each other. Combined with `git pull origin main`, the job also deploys whatever is on `main`, not what was tested. |
| 2 | **`echo "... DB=$DB_PASSWORD"`** | The production DB password is printed in plain text in every job log, visible to everyone with project access, and kept forever. The variable isn't masked, so GitLab doesn't hide it. |
| 3 | **Builds on the production servers** (`git pull`, `npm install`, `docker build` on each host) | Builds compete with live traffic for CPU and RAM. Each server builds its own image, so web-1 and web-2 can run *different* code (if `main` moves between the two iterations, or `npm install` resolves differently). A failed `npm install` (registry down) leaves a broken tree. Nothing is tested before it's live. |
| 4 | **`docker stop && docker rm && docker run` with no health check, on both hosts in a row** | Each host is down while the new container starts (no draining from the ALB), giving 5xx errors to users on every deploy. If the new version crashes, the loop happily moves on and breaks the **second** server too, so 100% outage. That's last month's 40-minute incident. |
| 5 | **No rollback path** | `:latest` is overwritten on each build, so the previous image is gone. Rolling back means SSH + `git checkout` + rebuild by hand under pressure (40 minutes). |
| 6 | **`npm run migrate` runs on every host, on the host (not in the image), before the new code is built** | Migrations run twice, possibly concurrently. If the build fails afterwards, the DB has been migrated but the old code is still running. If the migration isn't backward compatible, the old version breaks immediately. |
| 7 | **Errors inside the loop are ignored** | In a multi-line `- \|` block the `for` loop's exit status is that of the *last* iteration. A failure on web-1 can be followed by a "successful" web-2 and a green pipeline. |
| 8 | **`StrictHostKeyChecking=no`** | Any host that answers on that IP (MITM, a recycled IP) receives the root SSH session and its commands. |
| 9 | **SSH as `root` with a private key in an unprotected, unmasked variable**, written to `key.pem` in the workspace and never deleted | Any branch or any MR can run `cat key.pem` or `echo $PROD_SSH_KEY` and get root on production. The file stays on the runner's disk. |
| 10 | **`docker run` without the flags `rc.local` uses** (no restart policy, no env/secrets, `0.0.0.0:3000`) | After a deploy the container has no `DB_PASSWORD` and no restart policy, so the first crash is permanent. The two start methods disagree. |
| 11 | **No concurrency control** (`concurrent = 4` on the runner, no `resource_group`) | Two pipelines can deploy at the same time and interleave `stop`/`run` on the same host. |
| 12 | **`image: alpine:latest`** + `apk add` each run, and hard-coded host IPs | Non-reproducible job image; a new server isn't deployed to until someone edits YAML. |
| 13 | **No tests, no lint, no image scan, no environment tracking, no notification** | Nothing stops a broken build. GitLab shows no deployment history, so nobody knows what's live. |

### 2. Review the runner setup (File D2 and the facts). 
List the risks, then describe how you would set up GitLab Runners for KerjaKu: where they run, which executor, how they get AWS access, how build jobs are kept apart from production deploys, and which settings you would use for tags, protected branches and variables. (6 pts)
---
| Risk | Impact |
|---|---|
| Runner lives on **web-1, a production web server** | Every CI job (any project's) runs next to production traffic. Builds steal CPU and RAM, and a compromised job means a compromised production server. |
| **`privileged = true` + `/var/run/docker.sock` mounted** | Either one alone gives any job **root on the host**: `docker run -v /:/host …`. That means root on web-1, with its `.env` and network access to RDS. |
| **`/root/.ssh` mounted into every job** | Any job can read root's private keys and `known_hosts` and SSH to every server those keys open. |
| **Instance runner + runs untagged jobs + not limited to protected branches** | *Any* project on the GitLab server, from *any* branch or MR, by *any* developer, runs on that production box. An intern's test project = root on prod. |
| **Variables not Protected/Masked** | Any branch's job can read `PROD_SSH_KEY` and `DB_PASSWORD`; they also show up in logs. |
| **Shared `/cache` volume** across all projects | Cache poisoning: one project can plant a modified `node_modules` that another project then ships. |
| Runner token in plain text; `alpine:latest` default image; `concurrent = 4` on a 4 GB web server | Token leaks give the ability to impersonate the runner and steal jobs (and their secrets). Unpinned images. OOM risk on prod. |
---
How I'd set up GitLab Runners for KerjaKu
| Question | Design |
|---|---|
| **Where they run** | On **dedicated** EC2 in **private subnets** of a separate "CI" subnet/SG, never on web servers. Two separate pools: **build** and **deploy**. The CI SG has no inbound rules and is not allowed into the RDS SG. |
| **Executor** | **Build:** `docker-autoscaler` (GitLab's fleeting AWS plugin) with an ASG of spot instances. **One job per VM, then it's destroyed** (`max_use_count = 1`). Because each VM is disposable, `privileged` (for docker-in-docker builds) is acceptable *only here*. Config: [`runner/config.build.toml`](part2-pipeline/runner/config.build.toml). **Deploy:** a small dedicated `docker` executor, **not privileged, no host volumes, no docker.sock**, `concurrent = 1`. Config: [`runner/config.deploy.toml`](part2-pipeline/runner/config.deploy.toml). |
| **AWS access** | **No AWS keys anywhere.** Jobs use **GitLab OIDC (`id_tokens`) → `AssumeRoleWithWebIdentity`**, which gives 1-hour credentials per job. Each role's trust policy is pinned to the GitLab `sub` claim: the build role accepts `project_path:kerjaku/web:*` and can only push to the `kerjaku-app` ECR repo. The deploy role accepts only `project_path:kerjaku/web:ref_type:branch:ref:main` and can only call ELB (de)register on our target group, `ssm:SendCommand` to instances tagged `App=kerjaku`, and Get/Put on `/kerjaku/prod/*` parameters. *Caveat:* with self-hosted GitLab, AWS STS must be able to reach `https://gitlab…/.well-known/openid-configuration` and the JWKS URL. If GitLab can't be exposed for that, the fallback is an **instance profile on the deploy runner host**, which is safe only because that runner is protected and project-locked. |
| **Build vs. deploy separation** | Different runners, different tags (`kerjaku-build`, `kerjaku-deploy`), different IAM roles. Build jobs (which run MR code) can't deploy: they have no deploy role and can't use the deploy runner. Deploy jobs run *no project code except our deploy scripts*. They call AWS APIs and **SSM Run Command** (no SSH, no keys, every command logged in CloudTrail). |
| **Registration scope & tags** | Build runner = **group runner** for `kerjaku/*`, not an instance runner. Deploy runner = **project runner** locked to `kerjaku/web`. **"Run untagged jobs" = off** on both. |
| **Protected branches** | `main` and `v*` tags are protected: merge only via MR, ≥1 approval, pipeline must pass, no force-push. The **deploy runner is marked "Protected"**, so it only runs jobs from protected refs. |
| **Protected environments** | `production` is a protected environment: only the "deployers" group may run its jobs (optionally with a required approval for out-of-hours deploys). |
| **Variables** | The only CI/CD variables are non-secret config (ARNs, region). Anything sensitive (ideally nothing) is **Protected + Masked and hidden + scoped to `environment: production`**. App secrets live in Secrets Manager and never pass through CI. |
| **Hygiene** | The runner token is rotated now (it's been on a shared host) and the file is `0600`. `allowed_images`/`allowed_services` are restricted to ECR + pinned public images. Cache goes to S3 per project, not a shared host dir. Runner managers are built from IaC. The old web-1 runner is unregistered and removed. |
---
### 3. Design a better deployment process for KerjaKu. 
It must cover:
- zero-downtime releases across both servers behind the ALB
- a one-step rollback to the previous version, in under 5 minutes
- where images are built and stored, and how they are tagged
- how database migrations run safely (including a migration that would break the old version still running)
- how secrets reach the app

A diagram or numbered steps is fine. Write the new `.gitlab-ci.yml` , or detailed pseudo-YAML. (10 pts)

---
Full files: [`.gitlab-ci.yml`](part2-pipeline/.gitlab-ci.yml), [`scripts/rolling-deploy.sh`](part2-pipeline/scripts/rolling-deploy.sh), [`scripts/kerjaku-host-deploy`](part2-pipeline/scripts/kerjaku-host-deploy) (installed on every web server), [`scripts/lib.sh`](part2-pipeline/scripts/lib.sh).


Flow
```
 MR pipeline:   lint + unit tests ─► secret detection ─► build image (not pushed to prod tags)
 main pipeline:
 ┌────────┐   ┌──────────────────────┐   ┌──────────────┐   ┌──────────────────────────────┐   ┌────────┐
 │  test  │──►│ build → ECR          │──►│ ▶ migrate    │──►│ rolling deploy               │──►│ verify │
 │        │   │ kerjaku-app:<sha>    │   │ (manual btn, │   │ host 1: drain→deploy→check→  │   │ smoke  │
 │        │   │ scan, block CRITICAL │   │  once, new   │   │         register→healthy     │   │ test   │
 └────────┘   └──────────────────────┘   │  image)      │   │ host 2: same                 │   └────────┘
                                         └──────────────┘   │ fail → that host rolls back, │
                                                            │        pipeline stops (red)  │
 ▶ rollback (manual, any time): rolling deploy of /kerjaku/prod/previous_image, no build, no migration
```
---
Zero-downtime releases across both servers
`rolling-deploy.sh` does, **one server at a time**:
1. **Pre-check:** all targets must be healthy and there must be ≥ 2. Otherwise it refuses to start, because taking a host out of a degraded fleet would cause an outage.
2. **Deregister** the host from the ALB target group and `wait target-deregistered`. The ALB stops sending new requests and lets in-flight ones finish. Target group `deregistration_delay = 30s`, down from the 300 s default. That one setting decides whether a deploy takes 2 minutes or 10.
3. **Deploy on the host via SSM Run Command:** `kerjaku-host-deploy deploy <image>` pulls the image from ECR, refreshes secrets from Secrets Manager, saves the current release as `release.env.previous`, runs `docker compose up -d --wait` (waits for the container healthcheck), then runs **`post-deploy-check.sh`** (Part 5).
4. **If anything fails:** that host is rolled back to its previous image and put back in the target group, and the pipeline stops red. **The other host never received the bad release**, so users see no outage, only reduced capacity for a minute.
5. **Register** the host and `wait target-in-service` (the ALB health check on `/health` must pass), then move on to the next host.
6. After all hosts succeed, record the release: SSM Parameter `/kerjaku/prod/previous_image` ← old, `/kerjaku/prod/current_image` ← new. New ASG instances read `current_image` at boot (Part 3), so scale-out never launches a stale or "latest" version.

Capacity note: with 2 servers, one carries 100% of traffic during a deploy. web-1 (4 GB) can't. Both servers need the same size (Part 4), or we deploy with 3 instances (scale out by one first). Once the ASG from Part 3 exists, this becomes **ASG instance refresh** with `min_healthy_percentage = 100` and `max_healthy_percentage = 200` (new instances come up *before* old ones leave). It's the same process, managed by AWS.
---
One-step rollback in under 5 minutes
- Every build is kept in ECR as an **immutable** `kerjaku-app:<git-sha>` (tag immutability on; lifecycle policy keeps the last 50).
- **The `rollback_production` job** (manual button on every `main` pipeline) runs the same rolling deploy with `/kerjaku/prod/previous_image`. GitLab's own *Environments → production → Rollback* button does the same thing by re-running an older pipeline's deploy job (its `$IMAGE` is still in ECR).
- **Why < 5 min:** no build, no migration. The previous image is usually still cached on the host (we prune only images older than 7 days). Per host it's about 30 s drain + 30 s container switch + 30 s ALB health check, so ~1.5 min. Two hosts ≈ 3 min.
- Rollback only works if the **database is still compatible with the old version**. That's why migrations follow the rule below.
---
Where images are built, stored and tagged
- **Built** once per commit in CI, on ephemeral build runners. Never on servers.
- **Stored** in **Amazon ECR** (`kerjaku-app`, same region), with scan-on-push enabled. The pipeline fails on CRITICAL findings.
- **Tagged** with `:<full git SHA>`, which is what is deployed and rolled back. Release tags (`v2.14.0`) get an extra alias for humans. **`latest` is never used** for deploys. Image labels record the commit and pipeline URL, and the running version is visible in `/health`.
---
Migrations, safely: "expand → migrate → contract"
- Migrations run **once**, as their own pipeline step **before** the code rollout, using the **new image** (`kerjaku-host-deploy migrate <image>` on one host via SSM, so the DB password never touches CI). The migration tool takes a DB lock, so an accidental second run waits.
- **Rule: every migration must work with both the old and the new code**, because during a rolling deploy (and after a rollback) both versions run against the same schema.
- **A change that would break the old version is split across releases.** Example: renaming `jobs.salary` → `jobs.salary_min`:
  1. **Release A (expand):** add `salary_min` (nullable). Code writes **both** columns and reads the old one.
  2. **Backfill** in batches (a background SQS job, 1 000 rows at a time, not one huge `UPDATE` that locks the table).
  3. **Release B:** code reads `salary_min`, still writes both. Rollback to A is still safe.
  4. **Release C (contract):** a week later, once rollback to A is no longer needed, drop `salary`.
- **MySQL 8 specifics:** use `ALGORITHM=INSTANT` or `INPLACE, LOCK=NONE` where possible, set a low `lock_wait_timeout` in the migration session so a blocked DDL fails instead of queuing every query behind it, and use `gh-ost`/`pt-online-schema-change` for big tables (e.g. `jobs`, ~480k rows).
- **Guardrails:** a CI check (`npm run migrations:check`) fails if a migration contains `DROP`/`RENAME`/`NOT NULL without default` unless the MR has a `db-contract` label and a second approval. RDS automated backups + point-in-time recovery are on. For risky migrations, take a manual snapshot first.
---
How secrets reach the app
- Secrets live in **AWS Secrets Manager** (`kerjaku/prod/app`). Each web server's **EC2 instance role** may read only `kerjaku/prod/*`.
- At deploy (and boot), `kerjaku-host-deploy` writes them to `/etc/kerjaku/kerjaku.env` (`root:root 0600`), which Compose passes to the container. Next step: the app reads Secrets Manager directly with the AWS SDK (cached, re-fetched on auth failure, so rotation works).
- **The pipeline never sees app secrets.** It only has short-lived OIDC credentials that can't read them.
---
`.gitlab-ci.yml` (abridged; full file in the repo)
```yaml
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/

stages: [test, build, deploy, verify]

variables:
  IMAGE: ${ECR_REGISTRY}/kerjaku-app:${CI_COMMIT_SHA}

.aws_oidc:
  id_tokens: { AWS_ID_TOKEN: { aud: sts.amazonaws.com } }
  before_script:
    - export AWS_WEB_IDENTITY_TOKEN_FILE="$(mktemp)"
    - printf '%s' "$AWS_ID_TOKEN" > "$AWS_WEB_IDENTITY_TOKEN_FILE"

lint_and_unit_test:  { stage: test,  tags: [kerjaku-build], image: node:20.18-bookworm-slim, script: [npm ci, npm run lint, npm test, npm run migrations:check] }

build_image:
  stage: build
  tags: [kerjaku-build]
  extends: .aws_oidc
  variables: { AWS_ROLE_ARN: arn:aws:iam::123456789012:role/gitlab-kerjaku-build }
  script: [ecr login, skip if tag exists, docker build --pull -t $IMAGE ., docker push, block on CRITICAL CVEs]

.deploy_base:
  extends: .aws_oidc
  tags: [kerjaku-deploy]          # protected runner
  resource_group: production      # one deploy at a time
  interruptible: false
  variables: { AWS_ROLE_ARN: arn:aws:iam::123456789012:role/gitlab-kerjaku-deploy }

migrate_database:
  extends: .deploy_base
  stage: deploy
  environment: { name: production, action: prepare }
  rules: [{ if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH, when: manual }]   # the "Deploy" button
  allow_failure: false
  script: ["./scripts/run-on-one-host.sh \"/usr/local/bin/kerjaku-host-deploy migrate '$IMAGE'\""]

deploy_production:
  extends: .deploy_base
  stage: deploy
  needs: [build_image, migrate_database]
  environment: { name: production, url: https://kerjaku.example.com }
  script: [./scripts/rolling-deploy.sh "$IMAGE"]

verify_production:
  stage: verify
  needs: [deploy_production]
  script: [curl /health, /, /jobs through the public URL; fail on non-200]

rollback_production:
  extends: .deploy_base
  stage: deploy
  environment: { name: production }
  rules: [{ if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH, when: manual }]
  variables: { RECORD_PREVIOUS: "false" }
  script:
    - PREVIOUS_IMAGE=$(aws ssm get-parameter --name /kerjaku/prod/previous_image --query Parameter.Value --output text)
    - ./scripts/rolling-deploy.sh "$PREVIOUS_IMAGE"
```
---