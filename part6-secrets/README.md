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

