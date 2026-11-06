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

### 2. Review the runner setup (File D2 and the facts). List the risks, then describe how you would set up GitLab Runners for KerjaKu: where they run, which executor, how they get AWS access, how build jobs are kept apart from production deploys, and which settings you would use for tags, protected branches and variables. (6 pts)
| Risk | Impact |
|---|---|
| Runner lives on **web-1, a production web server** | Every CI job (any project's) runs next to production traffic. Builds steal CPU and RAM, and a compromised job means a compromised production server. |
| **`privileged = true` + `/var/run/docker.sock` mounted** | Either one alone gives any job **root on the host**: `docker run -v /:/host …`. That means root on web-1, with its `.env` and network access to RDS. |
| **`/root/.ssh` mounted into every job** | Any job can read root's private keys and `known_hosts` and SSH to every server those keys open. |
| **Instance runner + runs untagged jobs + not limited to protected branches** | *Any* project on the GitLab server, from *any* branch or MR, by *any* developer, runs on that production box. An intern's test project = root on prod. |
| **Variables not Protected/Masked** | Any branch's job can read `PROD_SSH_KEY` and `DB_PASSWORD`; they also show up in logs. |
| **Shared `/cache` volume** across all projects | Cache poisoning: one project can plant a modified `node_modules` that another project then ships. |
| Runner token in plain text; `alpine:latest` default image; `concurrent = 4` on a 4 GB web server | Token leaks give the ability to impersonate the runner and steal jobs (and their secrets). Unpinned images. OOM risk on prod. |

#### How I'd set up GitLab Runners for KerjaKu
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

