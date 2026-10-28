# Sovereign Ops — 24/7 Autonomous Revenue Infrastructure
Runs the owner's digital company control plane on GitHub Actions (public repo = free unlimited minutes).

## Always-on workflows
| Workflow | Schedule | Job |
|---|---|---|
| `a1-retry` | every 30 min | Launch OCI A1 Ampere (2 OCPU/12GB) when capacity frees; Telegram alert on success |
| `payment-watcher` | hourly | Poll Gumroad sales API + gateways; Telegram alert on new money |
| `vm-watch` | every 20 min | SSH-health of the Oracle micro VM + auto-rescue (swap/timers) |
| `revenue-report` | 2×/day | Daily revenue vs $1,000/day goal → Telegram briefing |

Secrets required (set via `gh secret set`): OCI_TENANCY, OCI_USER, OCI_FINGERPRINT, OCI_KEY_B64, OCI_REGION, TG_TOKEN, TG_CHAT, GUMROAD_TOKEN
