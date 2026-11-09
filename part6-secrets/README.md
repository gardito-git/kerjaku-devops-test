# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 6 — Secrets management (10 points)
KerjaKu's secrets are spread across three places today:
- .env files on each web server, copied by hand when a server is rebuilt.
- GitLab CI/CD variables, used by pipelines (see Part 2).
- Chat: when a developer needs the production database password or an API key, a senior developer sends it in a WhatsApp or Slack message.
Last month, a developer who left six months ago was found to still have the production
.env file on a personal laptop.

Questions
1. How should developers get access to passwords and keys they need (for example, database access for debugging, or a third-party API key), instead of sharing them in chat? Cover the tools, who can access what, and what happens when someone leaves the company. (3 pts)
2. What are the limits of GitLab CI/CD variables for storing secrets? Compare them with **AWS Secrets Manager** and **AWS Systems Manager Parameter Store**. Which would you use for KerjaKu, and how would (a) the GitLab pipeline and (b) the running app get secrets at run time, without any long-lived AWS keys? (4 pts)
3. The production database password has been in chat and .env files for two years. Describe how you would rotate it without downtime, and how you would make rotation routine from now on. (3 pts)

### 1. How developers get the secrets they need
**Principle:** people get access to *systems* through their own identity, not copies of shared passwords. Machine secrets are fetched by machines, not passed around by people.

- **Identity:** **AWS IAM Identity Center (SSO)** connected to the company IdP (Google Workspace / Microsoft Entra), with MFA enforced. GitLab also logs in via the same IdP (SAML/OIDC).
- **Machine secrets** (DB credentials, third-party API keys) live in **AWS Secrets Manager**, under paths like `kerjaku/{dev,staging,prod}/<service>`. Access is by IAM policy:

  | Who | dev / staging secrets | prod secrets |
  |---|---|---|
  | All developers (`Developer` permission set) | read | **none** |
  | Tech lead / on-call (`ProdSupport` permission set) | read | read **specific** secrets, time-limited (1–8 h session), every read logged in CloudTrail |
  | DevOps (`Admin`, break-glass) | full | full, with an alert on use |
  | Apps (EC2 instance roles) | — | only their own `kerjaku/prod/<app>/*` |

- **Database access for debugging:** no shared DB password. Each developer has a **personal MySQL user mapped to IAM** (**RDS IAM database authentication**: `aws rds generate-db-auth-token` gives a 15-minute token). They connect through **SSM Session Manager port forwarding** (no bastion keys, no public RDS). By default they get **read-only on a read replica**. Write access to prod is a time-boxed, approved, logged exception.
- **Third-party API keys a developer needs locally:** use the **dev/sandbox** key from `kerjaku/dev/*`. Production keys don't belong on laptops at all.
- **Human-only logins** (vendor dashboards, domain registrar) go in a **team password manager** (1Password/Bitwarden Business) with SSO, shared vaults per team, and access logs. Never in WhatsApp or Slack.
- **Policy plus detection:** "no secrets in chat or in Git" is written down. GitLab Secret Detection runs on every MR. Slack DLP / secret scanning flags tokens posted in chat.
- **When someone leaves:** HR offboarding disables the user **in the IdP**, which immediately revokes AWS SSO, GitLab, the password manager and Slack. Their personal DB user is dropped (it's IAM-mapped, so it already can't get tokens). Because nobody held long-lived prod secrets locally, there's nothing to chase. We still use CloudTrail to list **which secrets they read in the last 90 days and rotate those** (rotation is automated, see 6.3). Laptops are company-managed (MDM) and wiped on return.

The developer who left six months ago with the prod `.env` is exactly what this prevents. As an immediate action, **everything in that `.env` gets rotated now**.

### 2. GitLab CI/CD variables vs Secrets Manager vs Parameter Store (4 pts)

**Limits of GitLab CI/CD variables for secrets:**

- They only exist **inside CI jobs**. The running app can't use them, so they get copied into `.env` files, which is today's mess.
- **Anyone with Maintainer** can view and change them. Anyone who can push a branch can read **unprotected** ones by echoing them in a job (exactly D1).
- **Masking is best-effort:** it only works for values meeting format rules (≥ 8 chars, limited charset) and is trivially bypassed (`base64`, printing character by character). Variables are plain env vars, so every tool and dependency in the job can read them.
- **No rotation, no versioning, no audit of reads**, and no fine-grained per-secret access control. They live in the GitLab DB on a self-hosted EC2 whose backups and security are on us.
- Size and type limits; secrets are duplicated per project.

**Comparison:**

| | GitLab CI/CD variables | AWS Secrets Manager | SSM Parameter Store (SecureString) |
|---|---|---|---|
| Usable by | CI jobs only | CI + app + people (via IAM) | CI + app + people (via IAM) |
| Encryption | GitLab DB encryption | KMS | KMS |
| Access control | project/group role, protected refs, env scope | IAM + resource policies, per secret | IAM, per parameter/path |
| Audit of reads | no | CloudTrail, per read | CloudTrail, per read |
| Versioning | no | yes (`AWSCURRENT` / `AWSPREVIOUS` labels) | yes (versions + labels) |
| **Automatic rotation** | no | **yes**, incl. managed RDS rotation, single/alternating-user strategies | no (DIY via Lambda) |
| Cross-account sharing | no | yes (resource policy) | advanced tier only |
| Size | ~10 KB | 64 KB | 4 KB standard / 8 KB advanced |
| Cost | free | $0.40/secret/month + $0.05 per 10k calls | standard tier free (higher-throughput & advanced tier paid) |

**What I'd use for KerjaKu:**

- **Secrets Manager** for real secrets: RDS credentials (with **automatic rotation**), third-party API keys, JWT/session signing keys. About 10–20 secrets ≈ USD 4–8/month, trivial next to one outage.
- **Parameter Store (String, free)** for non-secret config: feature flags, endpoints, `current_image` / `previous_image` pointers.
- **GitLab variables:** only non-sensitive pipeline config (role ARNs, region). **No secrets, and especially no AWS keys.**

**(a) How the pipeline gets AWS access and secrets without long-lived keys:**
GitLab issues a per-job **OIDC ID token** (`id_tokens:` with `aud: sts.amazonaws.com`). The job exchanges it via **`sts:AssumeRoleWithWebIdentity`** for credentials that last ≤ 1 hour. AWS has an IAM OIDC provider for `gitlab.kerjaku.example.com`, and each role's trust policy checks the token's `sub` claim, e.g. `project_path:kerjaku/web:ref_type:branch:ref:main`, so a feature branch or another project **can't** assume the deploy role. If a job truly needs a secret, it calls `secretsmanager:GetSecretValue` with that short-lived role, but in my design the deploy pipeline doesn't need any app secrets at all. *(Self-hosted caveat: AWS must reach GitLab's `/.well-known/openid-configuration` and JWKS over HTTPS. If that can't be exposed, the fallback is an instance profile on the protected, project-locked deploy runner.)*

**(b) How the running app gets secrets at run time:**
The EC2 instances (launch template, Part 3) have an **instance profile**. The AWS SDK gets **automatically rotated temporary credentials from IMDSv2**, with no keys on disk. The role may only `GetSecretValue` on `kerjaku/prod/*`. At startup the app calls Secrets Manager (with the AWS caching client, ~5-minute TTL) and, on a DB authentication error, re-fetches the secret and reconnects, so rotation needs no restart. (Interim step until the app code changes: `kerjaku-host-deploy` fetches the secret into a root-only env file at deploy/boot, as in Part 1.3.)

### 3. Rotating the production DB password without downtime (3 pts)

**One-off rotation now** (the password has been in chat and `.env` files for two years, so assume it's compromised):

1. **Inventory every consumer:** web app (both servers), SQS workers (CV parsing, email), cron jobs, the migration job, BI/reporting tools, developers' SQL clients. Check `SELECT user, host, COUNT(*) FROM information_schema.processlist GROUP BY user, host;` to see who actually connects. Anything we miss would break at step 5, so this matters.
2. **Store the new credential first:** put a strong random password in Secrets Manager `kerjaku/prod/db-app`.
3. **Use MySQL 8 dual passwords** (8.0.14+, supported on RDS):
   ```sql
   ALTER USER 'kerjaku_app'@'%' IDENTIFIED BY '<new>' RETAIN CURRENT PASSWORD;
   ```
   Now **both the old and new passwords work**, so nothing breaks while we roll out.
4. **Roll out the new password** to every consumer through the normal rolling deploy (the deploy script refreshes secrets from Secrets Manager). Connection pools reconnect with the new password. There's no downtime, because the old password is still valid for any connection that hasn't switched yet.
5. **Verify** nothing still uses the old password. RDS logs failed logins, so once the old one is discarded any straggler shows up immediately. Before that, confirm via performance_schema / the inventory that all known clients were redeployed. Then:
   ```sql
   ALTER USER 'kerjaku_app'@'%' DISCARD OLD PASSWORD;
   ```
   The leaked password is now useless, including the copy on the ex-employee's laptop.
6. **Also:** rotate the RDS **master** password (and switch it to RDS-managed `manage_master_user_password = true`, stored and rotated in Secrets Manager); make sure the app user has only the grants it needs (no `SUPER`/DDL; migrations use a separate `kerjaku_migrate` user); delete the `.env` copies and GitLab variables; check that RDS isn't publicly accessible and its SG allows only the web/worker SGs, which limits what a leaked password could ever do.

*Alternative if dual passwords aren't an option:* create a **second user** `kerjaku_app_v2` with identical grants, switch consumers to it, then lock and drop the old user. That's the same "two valid credentials during the switch" idea.

**Making rotation routine:**

- Turn on **Secrets Manager automatic rotation** for `kerjaku/prod/db-app` every **30–90 days** using the **alternating-users** strategy (AWS template `SecretsManagerRDSMySQLRotationMultiUser`). It keeps two DB users and flips between them, so at any moment the "current" and "previous" credentials both work. That's zero downtime by design.
- The app must **refresh credentials on auth failure** and set a **max connection lifetime** (e.g. 30 min) in its pool so connections naturally pick up the new secret.
- **Alert** on rotation failure (EventBridge `RotationFailed` → Slack/on-call) and test rotation in staging first.
- **Rotate on events**, not just on the calendar: whenever someone with prod secret access leaves (CloudTrail shows what they read), or a secret appears in chat or Git.
