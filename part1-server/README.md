# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 1 - Server and Nginx configuration review (20 points)
You inherit the web servers below. Review the configs as if they were about to be copied
to two new servers.

### File A - /etc/nginx/sites-enabled/kerjaku.conf
```yaml
server {
    listen 80;
    server_name kerjaku.example.com;

    client_max_body_size 500M;
    autoindex on;
    root /var/www/kerjaku;

    location / {
        proxy_pass http://127.0.0.1:3000;
    }

    location /uploads {
        alias /var/www/kerjaku/uploads;
    }

    location ~ /\.env {
        allow all;
    }
}
```

### File B - /etc/ssh/sshd_config (excerpt)
```yaml
Port 22
PermitRootLogin yes
PasswordAuthentication yes
MaxAuthTries 10
```

### File C - how the app is started (from /etc/rc.local )
```cd /var/www/kerjaku && 
sudo docker run -d -p 0.0.0.0:3000:3000 \-e DB_PASSWORD=Kerja2024! -v /var/www/kerjaku:/app kerjaku-app:latest
```
### Extra facts: 
the security group allows inbound 22 and 3000 from `0.0.0.0/0`. 
The ALBterminates HTTPS and forwards to port 80. 
The disk alert fired twice last month because `/var/log` filled up.
## Questions
1. List every issue you find across Files A–C and the extra facts. Rate each Critical / High / Medium / Low and give one line on why. (8 pts)
2. Rewrite File A as you would deploy it. Include the headers and settings you would add for a site behind an ALB. (6 pts)
3. Replace File C with a better way to run the container so it restarts on failure and on reboot, without secrets on the command line. Explain your choice. (3 pts)
4. How would you stop `/var/log` filling up again? (3 pts)
## Answer

### 1. List every issue you find across Files A–C and the extra facts. Rate each Critical / High / Medium / Low and give one line on why. (8 pts)
File A:
- Critical
  - Issue

    `location ~ /\.env { allow all; }`
    ```yaml
    Regex locations win over `location /`, and this block has no `proxy_pass`, so Nginx serves `/var/www/kerjaku/.env` from `root` as a static file. Anyone can download the production secrets with `GET /.env`. The regex isn't anchored either, so `/anything/.env.bak` matches too.
    ```
- High
  - Issue

    `autoindex on` + `root /var/www/kerjaku` (the app's source directory)
    ```yaml
    Any path that falls through to static serving lists directory contents. `root` points at a directory that holds `.env`, `.git` and source code, so a single mistake in a location block exposes them.
    ```
    `location /uploads` serves CVs straight from local disk
    ```yaml
    CVs contain personal data (names, phone numbers, addresses) and are public to anyone who guesses or enumerates a filename. They can't be revoked and need no auth. Combined with `autoindex on`, the whole directory can be **listed**. There are also two servers with separate disks, so a file uploaded on web-1 returns 404 on web-2. Uploads should live in S3 (as the architecture says) and be served via short-lived pre-signed URLs after an authorization check. Uploaded HTML/SVG served from the main origin is also a stored-XSS vector.
    ```
- Medium
  - Issue

    No `X-Forwarded-For` / `X-Forwarded-Proto` / `Host` headers sent to the app; no `real_ip` configuration
    ```yaml
    The app sees every user as `127.0.0.1` and every request as plain HTTP. Effects: rate limiting and audit logs are useless, "secure" cookies and redirects to `http://` break, and there may be redirect loops.
    ```
    `client_max_body_size 500M`
    ```yaml
    CVs are a few MB. 500 MB lets a single client tie up workers and fill `/var/lib/nginx` and the disk.
    ```
    `location /uploads` without trailing slashes
    ```yaml
    The prefix also matches `/uploads-old`, `/uploads.bak` and so on, which map to sibling directories next to `uploads`. Use `location /uploads/ { alias …/uploads/; }` if this is kept at all.
    ```
    No `keepalive_timeout` tuned for the ALB, no proxy timeouts
    ```yaml
    Nginx's default keep-alive (75 s) happens to be fine, but if it's ever set below the ALB idle timeout (60 s) the ALB will reuse closed connections and return intermittent 502s. No `proxy_read_timeout` means slow requests behave unpredictably.
    ```
- Low
  - Issue

    No security headers (HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`), and `server_tokens` is on
    ```yaml
    Defence in depth against clickjacking, MIME sniffing and version fingerprinting.
    ```
    Only one `server` block, no `default_server`
    ```yaml
    Requests with any `Host` header are proxied to the app (host-header attacks, scanner noise in app logs).
    ```

File B:
- Critical
  - Issue

    SG allows 22 from `0.0.0.0/0`, with `PermitRootLogin yes`, `PasswordAuthentication yes` and `MaxAuthTries 10`
    ```yaml
    Internet-wide password brute force against root. One guessed password means full control of production.
    ```
- High
  - Issue

    `PermitRootLogin yes`
    ```yaml
    No per-person attribution, and root compromise is immediate. Use named accounts with sudo. Even better, use SSM Session Manager.
    ```
    `PasswordAuthentication yes`
    ```yaml
    Passwords can be guessed, phished or reused. Keys (or SSM) only.
    ```
- Medium
  - Issue

    `MaxAuthTries 10`
    ```yaml
    10 guesses per connection makes brute force 3–5× faster. Use 3.
    ```

File C:
- Critical
  - Issue

    SG allows 3000 from 0.0.0.0/0 and Docker publishes `0.0.0.0:3000`
    ```yaml
    The app is reachable directly from the internet, bypassing the ALB, TLS, Nginx and any WAF. Docker's iptables rules also bypass ufw, so a host firewall wouldn't help.
    ```
    `-e DB_PASSWORD=Kerja2024!` on the command line
    ```yaml
    The secret is visible in ps, /proc/*/cmdline, docker inspect, shell history and rc.local itself, which is world-readable by default. The password is weak, and the same value is shared in chat.
    ```
- High
  - Issue

    Started from `/etc/rc.local` with no `--name` and no restart policy
    ```yaml
    If the app crashes it stays down until someone notices. On reboot rc.local runs docker run again and creates a second unnamed container, while the old stopped one stays around. Also, the pipeline (D1) does docker stop kerjaku, which doesn't match this unnamed container. Two different start methods give unpredictable state.
    ```
    `-v /var/www/kerjaku:/app` bind-mounts the host source tree over the image
    ```yaml
    What runs is whatever is on disk (git pull result + host node_modules), not the tested image. That breaks reproducibility and rollback, and gives the container write access to the host code and .env.
    ```
- Medium
  - Issue

    `kerjaku-app:latest` tag
    ```yaml
    You can't tell which version is running, can't roll back to "the previous latest", and the two servers can silently run different code.
    ```
    No memory/CPU limit on the container
    ```
    A memory-hungry release drags the whole host into the kernel OOM killer (exactly what happens in Part 4).
    ```
- Low
  - Issue

    `sudo` inside `rc.local` (already root), and the container probably runs as root
    ```yaml
    Messy and misleading. The container should run as a non-root user with a read-only filesystem.
    ```

### 2. Rewrite File A as you would deploy it. Include the headers and settings you would add for a site behind an ALB. (6 pts)
Full fire: [`part1-server/nginx/kerjaku.conf`](part1-server/nginx/kerjaku.conf).
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
- **No `/uploads` location.** CVs move to a private S3 bucket (Block Public Access on, SSE-KMS). The app checks that the user may see the CV, then redirects to a pre-signed URL valid for ~5 minutes. This also fixes the "file only exists on one server" problem.
- **`real_ip` + forwarded headers.** Nginx logs the real client IP, and the app gets `X-Forwarded-Proto: https` so it builds `https://` links and sets `Secure` cookies (configure Express with `app.set('trust proxy', 'loopback')`). I pass the ALB's `X-Forwarded-For` through unchanged rather than using `$proxy_add_x_forwarded_for`, which would append the client IP a second time once `real_ip` has rewritten `$remote_addr`.
- **HSTS here or at the ALB?** The ALB can't add response headers, so Nginx adds them. `always` makes sure they're on error pages too.
- **`/health` is proxied to the app** so the ALB health check reflects whether the app is up (the Part 4 fix). `/nginx-health` stays for debugging Nginx only.
- **JSON access logs with `$http_x_amzn_trace_id`** to correlate a request across ALB logs → Nginx → app.
- **Security group (not Nginx)** limits port 80 to the ALB SG only. Port 3000 is no longer published outside `127.0.0.1`.

SSH hardening is in [`part1-server/ssh/10-kerjaku-hardening.conf`](part1-server/ssh/10-kerjaku-hardening.conf) (`PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 3`, `AllowGroups ssh-users`). The end state is **no port 22 at all**, with shell access through SSM Session Manager.

### 3. Replace File C with a better way to run the container so it restarts on failure and on reboot, without secrets on the command line. Explain your choice. (3 pts)
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