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