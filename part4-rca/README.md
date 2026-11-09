# Part 4 — Post-deployment incident (20 pts)

## 4.1 Root cause and evidence (6 pts)

**Root cause:** release **v2.14 added a startup step that loads all ~482k jobs into memory** ("Warming job cache"). That needs about **3.7 GB of resident memory**. **web-1 is a t3.medium with 4 GB RAM** (shared with the OS, Docker, Nginx), so the kernel **OOM killer kills the Node process** during warm-up. Docker restarts it, it loads the cache again, it is killed again, in a **crash loop**. web-2 is a t3.large (8 GB) and survives at 5.1 GB. The ALB keeps sending half the traffic to web-1 because its health check only tests Nginx.

**Evidence chain:**

1. **`dmesg`:** `Out of memory: Killed process … (node) … anon-rss: ~3.70 GB`, three times, about every 27–28 s (912044 → 912071 → 912099). `anon-rss` (real memory) is close to all of web-1's 4 GB. `total-vm` (5 GB) is virtual address space and not the problem.
2. **`docker ps`:** `Restarting (137)`. Exit code 137 = 128 + 9 = **SIGKILL**, which matches an OOM kill, not an application error.
3. **App log:** the last line before every restart is `Warming job cache: loading 482,113 jobs into memory…`. It dies during warm-up every time and never reaches "ready". The `[v2.14]` prefix ties it to the new release.
4. **Instance types differ:** web-1 has 4 GB, web-2 has 8 GB. The same image works on web-2 using 5.1 GB, which is more than web-1 has in total. That's why only one server fails.
5. **Timeline:** deployed 14:05. Failures appear as soon as v2.14 starts on web-1.
6. **"About half of page loads fail, randomly":** the ALB round-robins between two targets that are *both* marked healthy, so ≈ 50% of requests go to web-1 and get a 502.

**Side effects (symptoms, not causes):**

- **Nginx `connect() failed (111: Connection refused)` to 127.0.0.1:3000 → 502 Bad Gateway.** Nginx is fine. Nothing is listening on :3000 while Node restarts and warms up.
- **ALB shows web-1 healthy.** The health check (`/nginx-health`) is a static 200 from Nginx and never touches the app. That's a monitoring gap, not the cause.
- **RDS `Aborted connection … (Got an error reading communication packets)` since 14:10.** Node is SIGKILLed while holding open MySQL connections, so it never closes them cleanly and MySQL logs each one as aborted. RDS CPU at 34% is normal, so the database is a victim, not the cause. (Each restart also re-runs the big "load all jobs" query, which adds some load but not enough to matter here.)
- **`total-vm: 5 GB`** is not a leak indicator. It's normal for Node/V8.

## 4.2 Next 15 minutes to restore service (5 pts)

1. **(min 0–1) Declare the incident.** One incident lead, one person on comms. Post in `#incidents`: "502s on ~50% of requests since v2.14, investigating." **Freeze deploys** (and stop anyone from "just restarting things").
2. **(min 1–3) Stop the bleeding: take web-1 out of the ALB.** `aws elbv2 deregister-targets --target-group-arn … --targets Id=<web-1>`. All traffic now goes to web-2, which is healthy. Watch ALB `HTTPCode_ELB_5XX_Count` / `HTTPCode_Target_5XX_Count` drop to ~0 within a minute. Check web-2's CPU and memory can carry 100% (the cache is per-process and loaded once, so memory won't double; CPU is the thing to watch).
3. **(min 3–5) Check that rollback is safe.** Did v2.14 include a DB migration that v2.13 can't run against? (Check the release diff / migrations table.) If it was backward compatible (or there was none), roll back.
4. **(min 5–10) Roll back to v2.13 on web-1**, deploying the previous image tag, verify (`docker ps` shows `Up` with no restarts, `curl localhost:3000/health` → 200, memory steady), then **re-register web-1**. Then **roll web-2 back to v2.13 as well**, one host at a time. v2.14 is unsafe for the current fleet: it uses 5.1 of 8 GB on web-2 and would OOM there too as the job count grows, and I don't want two versions in production.
   *If rollback isn't possible* (e.g. an incompatible migration): keep web-1 out of service and resize it to t3.large (stop → change type → start, ~3–5 min), then put it back. That's fixing forward on infrastructure while the code is fixed.
5. **(min 10–13) Verify recovery:** both targets healthy, 5xx back to baseline, RDS aborted-connection warnings stopped, a synthetic page load from outside works.
6. **(min 13–15) Communicate and preserve evidence:** update stakeholders and send the CEO note (4.5). Save `dmesg`, container logs, Nginx logs and ALB metrics screenshots for the postmortem. Write down the timeline while it's fresh.

## 4.3 Why the ALB kept sending traffic to the broken server, and the fix (3 pts)

**Why:** the target group's health check path is **`/nginx-health`, which Nginx answers itself with a static 200**. It proves that Nginx is running, not that the **app** behind it can serve a request. The ALB only knows what the health check tells it, so web-1 stayed "healthy" while every real request got a 502.

**Fix:**

- **Health check path → `/health`, proxied by Nginx to the app** (already in the Part 1 config). The app's `/health` returns 200 only once it's **ready** (cache warmed, DB pool initialised). Keep it cheap and give dependency checks a short timeout. Don't make it fail just because RDS is slow, or a DB blip would mark *every* target unhealthy (the ALB "fails open" in that case, but you lose the signal).
- **Tighter thresholds:** interval 10 s, unhealthy threshold 2, healthy threshold 3, timeout 5 s, matcher `200`. A dead app is pulled out in ~20 s.
- **ASG `health_check_type = "ELB"`** (Part 3), so an instance that stays unhealthy is **replaced automatically**, not just bypassed.
- Optionally an ALB **anomaly mitigation** / per-target 5xx alarm as a second signal.

## 4.4 Permanent changes, monitoring and alerts (4 pts)

**Prevent:**

- **Fix the code:** don't load the entire `jobs` table into process memory at startup. Use a bounded LRU cache, paginate, cache only hot data, or move the cache to **ElastiCache (Redis)**, shared by all instances, which also means faster restarts. Add a load test with production-sized data in staging.
- **Consistent infrastructure:** every web server is the same instance type from one launch template / ASG (Part 3). Nobody "remembers why they differ" again.
- **Container memory limit + `--max-old-space-size`** (Part 1 compose file). The app fails with a clear "JavaScript heap out of memory" in its own log, inside its own cgroup, instead of a host-wide kernel OOM.
- **Staging that looks like production:** same instance type, realistic data volume. A release that needs 3.7 GB would have failed there first.

**Catch it sooner (in the deploy):**

- **Rolling deploy with `post-deploy-check.sh`** (Parts 2 + 5). web-1 would have shown restart count > 0 / failed health, been **auto-rolled back** before web-2 was touched, and the pipeline would have gone red at 14:06 with zero user impact.
- **App-aware ALB health check** (4.3).

**Monitoring and alerts** (CloudWatch, paged to on-call via SNS → Slack/PagerDuty):

| Signal | Alert |
|---|---|
| ALB `HTTPCode_ELB_5XX_Count` + `HTTPCode_Target_5XX_Count` as a % of requests | > 1% for 2 min → page |
| ALB `UnHealthyHostCount` | ≥ 1 for 2 min → page |
| **Container restarts** (CloudWatch agent / cAdvisor, or a cron that publishes `docker inspect` RestartCount) | any increase in 5 min → alert |
| **Kernel OOM kills:** CloudWatch Logs metric filter on `"Out of memory: Killed process"` from `/var/log/kern.log` | ≥ 1 → page |
| **Memory used %** per instance (CloudWatch agent `mem_used_percent`; EC2 doesn't report memory by default) | > 85% for 5 min → warn |
| Disk used % | > 80% → warn |
| Nginx 502/504 count per host (from JSON access logs) | spike after deploy → alert |
| **Synthetic check** (CloudWatch Synthetics canary loads `/` and `/jobs` every minute from outside) | 2 failures in a row → page |
| p95 latency (ALB `TargetResponseTime`) | > 1.5 s for 5 min → warn |
| RDS aborted connections / connection count | sudden jump → warn |

Plus **deploy markers** on the dashboard so "errors started at the deploy" is visible at a glance, and a blameless **postmortem** with owners and dates for each action.

## 4.5 Incident update for the CEO (2 pts)

> At 14:05 we released an update to the KerjaKu website. A new feature in it needed more memory than one of our two servers has, so that server kept crashing and about half of visitors saw an error page between roughly 14:10 and 14:30. We switched all traffic to the healthy server, rolled back the update, and the site has been working normally since 14:30. No data was lost. We are now fixing the feature and adding automatic checks that stop a faulty release before users see it, and I'll share a full review by tomorrow.

*(Times would be filled in with the real recovery time.)*