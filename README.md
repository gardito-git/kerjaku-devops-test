# kerjaku-devops-test
KerjaKu DevOps Engineer - Technical Assessment

All config files and scripts referenced below are in this repository:

| Folder | Contents |
|---|---|
| [`part1-server/`](part1-server/) | Nginx site config, SSH hardening, Docker Compose service, log rotation / journald / Docker log limits |
| [`part2-pipeline/`](part2-pipeline/) | 
| [`part3-terraform/`](part3-terraform/) | 
| [`part4-rca/`](part4-rca/) | 
| [`part5-script/`](part5-script/) | 
| [`part6-secrets/`](part6-secrets/) | 

## Global assumptions

- VPC CIDR is `10.0.0.0/16`; web servers are `10.0.1.11` (web-1) and `10.0.1.12` (web-2); the ALB is in public subnets and the web servers can be moved to private subnets with a NAT gateway (or VPC endpoints).
- The ALB HTTPS listener has a valid ACM certificate, and the ALB's port-80 listener redirects to 443.
- The app exposes (or can be given) a `GET /health` endpoint that returns 200 only when the app is ready to serve traffic.
- The AWS account ID used in examples is `123456789012`. Image registry = Amazon ECR in `ap-southeast-1`.
- The app is a single Docker image; the same image runs the web API and the SQS workers (workers are out of scope but would follow the same deploy process).
- "Developers" use GitLab with the *Developer* role; 1–2 senior people are *Maintainers*.

## If I started on Monday: what I'd fix first

Ordered by risk × effort. Most of these take minutes, and some are active exposures right now:

1. **Rotate everything that has leaked:** the AWS access key in `web.tf` (and in Terraform state in Git), the DB password (chat, `.env`, `rc.local`, pipeline logs), the runner token, and `shared-team-key`. Treat them as compromised.
2. **Close the security group:** remove `22` and `3000` from `0.0.0.0/0`, and allow only port 80 from the ALB security group.
3. **Delete the Nginx `.env` location and `autoindex`**: the production `.env` file is probably downloadable right now.
4. **Take the GitLab Runner off web-1**, mark CI/CD variables Protected and Masked, and stop echoing `DB_PASSWORD`.
5. **Point the ALB health check at the app (`/health`)**, not at a static Nginx page.

Then the structural work: the pipeline (Part 2), IaC and remote state (Part 3), and secrets (Part 6).

---

# Part 1 — Server and Nginx configuration review (20 pts)

## 1.1 Issues found (8 pts)

| # | Where | Issue | Rating | Why |
|---|---|---|---|---|
| 1 | File A | `location ~ /\.env { allow all; }` | **Critical** | Regex locations win over `location /`, and this block has no `proxy_pass`, so Nginx serves `/var/www/kerjaku/.env` from `root` as a static file. Anyone can download the production secrets with `GET /.env`. The regex isn't anchored either, so `/anything/.env.bak` matches too. |
| 2 | Extra facts + File C | SG allows **3000 from 0.0.0.0/0** and Docker publishes `0.0.0.0:3000` | **Critical** | The app is reachable directly from the internet, bypassing the ALB, TLS, Nginx and any WAF. Docker's iptables rules also bypass `ufw`, so a host firewall wouldn't help. |
| 3 | Extra facts + File B | SG allows **22 from 0.0.0.0/0**, with `PermitRootLogin yes`, `PasswordAuthentication yes` and `MaxAuthTries 10` | **Critical** | Internet-wide password brute force against **root**. One guessed password means full control of production. |
| 4 | File C | `-e DB_PASSWORD=Kerja2024!` on the command line | **Critical** | The secret is visible in `ps`, `/proc/*/cmdline`, `docker inspect`, shell history and `rc.local` itself, which is world-readable by default. The password is weak, and the same value is shared in chat. |
| 5 | File B | `PermitRootLogin yes` | **High** | No per-person attribution, and root compromise is immediate. Use named accounts with sudo. Even better, use SSM Session Manager. |
| 6 | File B | `PasswordAuthentication yes` | **High** | Passwords can be guessed, phished or reused. Keys (or SSM) only. |
| 7 | File A | `autoindex on` + `root /var/www/kerjaku` (the app's source directory) | **High** | Any path that falls through to static serving lists directory contents. `root` points at a directory that holds `.env`, `.git` and source code, so a single mistake in a location block exposes them. |
| 8 | File A | `location /uploads` serves CVs straight from local disk | **High** | CVs contain personal data (names, phone numbers, addresses) and are public to anyone who guesses or enumerates a filename. They can't be revoked and need no auth. Combined with `autoindex on`, the whole directory can be **listed**. There are also two servers with separate disks, so a file uploaded on web-1 returns 404 on web-2. Uploads should live in S3 (as the architecture says) and be served via short-lived pre-signed URLs after an authorization check. Uploaded HTML/SVG served from the main origin is also a stored-XSS vector. |
| 9 | File C | Started from `/etc/rc.local` with no `--name` and no restart policy | **High** | If the app crashes it stays down until someone notices. On reboot `rc.local` runs `docker run` again and creates a *second* unnamed container, while the old stopped one stays around. Also, the pipeline (D1) does `docker stop kerjaku`, which doesn't match this unnamed container. Two different start methods give unpredictable state. |
| 10 | File C | `-v /var/www/kerjaku:/app` bind-mounts the host source tree over the image | **High** | What runs is whatever is on disk (`git pull` result + host `node_modules`), not the tested image. That breaks reproducibility and rollback, and gives the container write access to the host code and `.env`. |
| 11 | Extra facts | `/var/log` filled the disk twice last month | **High** | A full disk breaks Nginx (can't write logs or temp bodies), Docker, MySQL clients and SSH logins, which means an outage. It will happen again. See 1.4. |
| 12 | File A | No `X-Forwarded-For` / `X-Forwarded-Proto` / `Host` headers sent to the app; no `real_ip` configuration | **Medium** | The app sees every user as `127.0.0.1` and every request as plain HTTP. Effects: rate limiting and audit logs are useless, "secure" cookies and redirects to `http://` break, and there may be redirect loops. |
| 13 | File A | `client_max_body_size 500M` | **Medium** | CVs are a few MB. 500 MB lets a single client tie up workers and fill `/var/lib/nginx` and the disk, a cheap DoS. |
| 14 | File C | `kerjaku-app:latest` tag | **Medium** | You can't tell which version is running, can't roll back to "the previous latest", and the two servers can silently run different code. |
| 15 | File C | No memory/CPU limit on the container | **Medium** | A memory-hungry release drags the whole host into the kernel OOM killer (exactly what happens in Part 4). |
| 16 | File A | `location /uploads` without trailing slashes | **Medium** | The prefix also matches `/uploads-old`, `/uploads.bak` and so on, which map to sibling directories next to `uploads`. Use `location /uploads/ { alias …/uploads/; }` if this is kept at all. |
| 17 | File B | `MaxAuthTries 10` | **Medium** | 10 guesses per connection makes brute force 3–5× faster. Use 3. |
| 18 | File A | No `keepalive_timeout` tuned for the ALB, no proxy timeouts | **Medium** | Nginx's default keep-alive (75 s) happens to be fine, but if it's ever set below the ALB idle timeout (60 s) the ALB will reuse closed connections and return intermittent 502s. No `proxy_read_timeout` means slow requests behave unpredictably. |
| 19 | File A | No security headers (HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`), and `server_tokens` is on | **Low** | Defence in depth against clickjacking, MIME sniffing and version fingerprinting. |
| 20 | File A | Only one `server` block, no `default_server` | **Low** | Requests with any `Host` header are proxied to the app (host-header attacks, scanner noise in app logs). |
| 21 | File C | `sudo` inside `rc.local` (already root), and the container probably runs as root | **Low** | Messy and misleading. The container should run as a non-root user with a read-only filesystem. |
| 22 | General | Configs are copied by hand to new servers; web-1 and web-2 already differ (instance types) | **Medium** | Configuration drift. Servers should come from one AMI + IaC (Part 3), not from copies. |

## 1.2 Rewritten File A (6 pts)

Full file: [`part1-server/nginx/kerjaku.conf`](part1-server/nginx/kerjaku.conf).

```nginx
set_real_ip_from 10.0.0.0/16;          # trust X-Forwarded-For only from inside the VPC (the ALB)
real_ip_header   X-Forwarded-For;
real_ip_recursive on;

log_format kerjaku_json escape=json '{"time":"$time_iso8601","client_ip":"$remote_addr",...,"amzn_trace_id":"$http_x_amzn_trace_id"}';

upstream kerjaku_app {
    server 127.0.0.1:3000 max_fails=0;
    keepalive 32;
}

# Unknown Host headers (scanners, ALB health checks use the IP as Host)
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    access_log off;
    location = /nginx-health { return 200 "ok\n"; }
    location = /health       { proxy_pass http://kerjaku_app/health; proxy_connect_timeout 2s; proxy_read_timeout 3s; }
    location /               { return 444; }
}

server {
    listen 80;
    server_name kerjaku.example.com;
    server_tokens off;
    # no root, no autoindex: Nginx serves nothing from disk

    client_max_body_size 10m;
    client_body_timeout  30s;
    keepalive_timeout    75s;            # > ALB idle timeout (60s), avoids 502s on reused connections

    access_log /var/log/nginx/kerjaku.access.log kerjaku_json;
    error_log  /var/log/nginx/kerjaku.error.log warn;

    if ($http_x_forwarded_proto = "http") { return 301 https://$host$request_uri; }

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "camera=(), microphone=(), geolocation=()" always;

    location ~ /\.(?!well-known/) { deny all; return 404; }   # .env, .git, ...

    location / {
        proxy_pass         http://kerjaku_app;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $http_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_set_header   X-Forwarded-Port  $http_x_forwarded_port;
        proxy_set_header   X-Amzn-Trace-Id   $http_x_amzn_trace_id;
        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
        proxy_send_timeout    60s;
    }
}
```

Key decisions:

- **No `/uploads` location.** CVs move to a private S3 bucket (Block Public Access on, SSE-KMS). The app checks that the user may see the CV, then redirects to a pre-signed URL valid for ~5 minutes. This also fixes the "file only exists on one server" problem.
- **`real_ip` + forwarded headers.** Nginx logs the real client IP, and the app gets `X-Forwarded-Proto: https` so it builds `https://` links and sets `Secure` cookies (configure Express with `app.set('trust proxy', 'loopback')`). I pass the ALB's `X-Forwarded-For` through unchanged rather than using `$proxy_add_x_forwarded_for`, which would append the client IP a second time once `real_ip` has rewritten `$remote_addr`.
- **HSTS here or at the ALB?** The ALB can't add response headers, so Nginx adds them. `always` makes sure they're on error pages too.
- **`/health` is proxied to the app** so the ALB health check reflects whether the app is up (the Part 4 fix). `/nginx-health` stays for debugging Nginx only.
- **JSON access logs with `$http_x_amzn_trace_id`** to correlate a request across ALB logs → Nginx → app.
- **Security group (not Nginx)** limits port 80 to the ALB SG only. Port 3000 is no longer published outside `127.0.0.1`.

SSH hardening is in [`part1-server/ssh/10-kerjaku-hardening.conf`](part1-server/ssh/10-kerjaku-hardening.conf) (`PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 3`, `AllowGroups ssh-users`). The end state is **no port 22 at all**, with shell access through SSM Session Manager.

## 1.3 Replacing File C (3 pts)

I'd remove the line from `rc.local` and run the app as a **Docker Compose service with a restart policy**: [`part1-server/app/compose.yml`](part1-server/app/compose.yml).

```yaml
services:
  app:
    image: ${KERJAKU_IMAGE}          # e.g. ...ecr.../kerjaku-app:3f9c2ab (from /etc/kerjaku/release.env)
    container_name: kerjaku
    restart: unless-stopped          # restarts on crash AND on reboot (docker.service is enabled)
    init: true
    stop_grace_period: 30s
    ports: ["127.0.0.1:3000:3000"]   # only Nginx can reach it
    env_file: [/etc/kerjaku/kerjaku.env]   # root:root 0600, written from Secrets Manager
    environment:
      NODE_ENV: production
      NODE_OPTIONS: --max-old-space-size=2560
    mem_limit: 3g
    read_only: true
    tmpfs: [/tmp]
    user: node
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    healthcheck: { test: [...GET /health...], interval: 10s, retries: 3, start_period: 60s }
    logging: { driver: json-file, options: { max-size: 50m, max-file: "5" } }
```

Started with:

```bash
docker compose -f /opt/kerjaku/compose.yml --env-file /etc/kerjaku/release.env up -d --wait
```

Why this choice:

- **Restart on failure and on reboot** comes from Docker's `unless-stopped` policy plus `systemctl enable docker`. Docker re-creates the container at boot from its stored config, so `rc.local` is no longer needed. I chose Docker's restart policy over a systemd unit wrapping `docker run --rm`, because Docker then tracks `RestartCount` and `OOMKilled`, which the post-deploy check (Part 5) and monitoring rely on. Each systemd restart would create a fresh container with a count of 0.
- **No secrets on the command line.** Docker reads them from a root-only file at container creation. The file is generated from **AWS Secrets Manager** by the deploy script using the instance role (no keys on disk; see Part 6). Remaining trade-off: root on the host can still see them via `docker inspect`. The final step is for the app to read Secrets Manager directly at startup with the AWS SDK, so nothing is written to disk.
- **No bind mount of the source tree.** The image *is* the release. **Pinned image tag** (git SHA) gives rollback by changing one line.
- **Memory limit and healthcheck**: a bad release kills only its own container, and `docker compose up --wait` fails fast if the app never gets healthy.

## 1.4 Stopping `/var/log` from filling up (3 pts)

1. **Find out what is actually growing** (`du -xh /var/log | sort -h | tail`, `journalctl --disk-usage`). It's usually Nginx access logs (including ALB health checks every few seconds), the journal, or app logs written to a file.
2. **Rotate by size, not only by day:** [`part1-server/logs/logrotate-nginx`](part1-server/logs/logrotate-nginx) uses `daily` + `maxsize 100M`, `rotate 7`, `compress`, and moves the logrotate timer to **hourly** (otherwise `maxsize` is only checked once a day).
3. **Cap the journal:** [`journald-kerjaku.conf`](part1-server/logs/journald-kerjaku.conf) sets `SystemMaxUse=500M`, `SystemKeepFree=2G`.
4. **Cap Docker container logs** (they live in `/var/lib/docker`, same disk): [`docker-daemon.json`](part1-server/logs/docker-daemon.json) sets `max-size 50m × 5 files`.
5. **Reduce noise:** `access_log off` for health checks; the app logs at `info`, not `debug`, in production.
6. **Ship logs off the box** with the CloudWatch agent (or Fluent Bit) to CloudWatch Logs with a retention policy (e.g. 30 days hot, then export to S3/Glacier). Local disk then only needs a few days of logs, and logs survive instance replacement (which matters once we use an ASG).
7. **Isolate and alert:** mount `/var/log` on its own EBS volume (or at least alert before it's full) so logs can never fill `/`. Add a CloudWatch alarm on `disk_used_percent > 80%` from the CloudWatch agent, which pages *before* the outage, not after.

---
