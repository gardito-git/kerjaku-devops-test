# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 6 — Secrets management (10 points)
KerjaKu's secrets are spread across three places today:
- .env files on each web server, copied by hand when a server is rebuilt.
- GitLab CI/CD variables, used by pipelines (see Part 2).
- Chat: when a developer needs the production database password or an API key, a senior developer sends it in a WhatsApp or Slack message.
Last month, a developer who left six months ago was found to still have the production
.env file on a personal laptop.
