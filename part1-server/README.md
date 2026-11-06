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

SG allows 22 from 0.0.0.0/0, with PermitRootLogin yes, PasswordAuthentication yes and MaxAuthTries 10
```yaml
Internet-wide password brute force against root. One guessed password means full control of production.
```
- High
- Issue

PermitRootLogin yes
```yaml
No per-person attribution, and root compromise is immediate. Use named accounts with sudo. Even better, use SSM Session Manager.
```
PasswordAuthentication yes
```yaml
Passwords can be guessed, phished or reused. Keys (or SSM) only.
```
- Medium
- Issue

MaxAuthTries 10
```yaml
10 guesses per connection makes brute force 3–5× faster. Use 3.
```
