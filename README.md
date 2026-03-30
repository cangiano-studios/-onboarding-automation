# Google Workspace Onboarding Automation

A Bash script that automates end-to-end onboarding of new employees
into Google Workspace for cangianostudios.com.

## Status

✅ Fully functional — tested end to end against a live Google Workspace
domain (cangianostudios.com). User creation, group membership, and
welcome email delivery all verified working.

---

## Requirements & Assumptions

**Requirements derived from the prompt:**
- Accept a CSV with columns: first_name, last_name, personal_email, department
- Create a Google Workspace user account (firstname.lastname@cangianostudios.com)
- Assign a temporary password with forced change on first login
- Add the user to their department Google Group
- Send a personalized welcome email to their personal address

**Assumptions made:**
- Domain is cangianostudios.com with an active Google Workspace subscription
- A GCP service account with Domain-Wide Delegation is configured
- Department Google Groups already exist before the script runs
- Email username format is firstname.lastname
- Script is idempotent — re-running the same CSV row logs warnings, not failures
- Welcome email is sent from the admin account (jeremy@cangianostudios.com)
  to avoid 2FA provisioning delays on brand new accounts
- The personal_email column is used as the To: address so new hires
  receive the welcome email before their first Workspace login

---

## API References

| Purpose | API | URL |
|---|---|---|
| Create Workspace user | Admin SDK Directory: users.insert | https://developers.google.com/admin-sdk/directory/reference/rest/v1/users/insert |
| Add user to group | Admin SDK Directory: members.insert | https://developers.google.com/admin-sdk/directory/reference/rest/v1/members/insert |
| Send welcome email | Gmail API: messages.send | https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send |
| OAuth2 token exchange | Service Account JWT flow | https://developers.google.com/identity/protocols/oauth2/service-account |
| Domain-Wide Delegation | DWD setup guide | https://developers.google.com/admin-sdk/directory/v1/guides/delegation |

---

## Architecture & Flow
```
new_hires.csv
     │
     ▼
onboard.sh (main loop)
     │
     ├─► get_access_token()    JWT signed with SA key → oauth2.googleapis.com/token
     │
     ├─► create_user()         POST /admin/directory/v1/users
     │                         Returns 201 (created) or 409 (exists, skip)
     │
     ├─► add_to_group()        POST /admin/directory/v1/groups/{group}/members
     │                         Returns 200 (added) or 409 (already member, skip)
     │
     ├─► get_access_token()    New token, gmail.send scope, sub = admin account
     │
     └─► send_welcome_email()  POST /gmail/v1/users/{userId}/messages/send
                               Base64url-encoded RFC 2822 MIME message
```

**Why two access tokens per user?**
The Admin SDK calls use the admin account as the DWD subject.
The Gmail send also uses the admin account so the email comes from
a trusted, established address rather than a brand new account that
hasn't completed 2FA setup yet.

---

## Prerequisites

- Google Workspace domain with super-admin access
- GCP project with Admin SDK and Gmail API enabled
- Service account with Domain-Wide Delegation configured
- 1Password CLI installed and authenticated (`brew install 1password-cli`)
- jq installed (`brew install jq`)
- Service account JSON key stored in 1Password as `onboarding-sa-key`

## Setup

1. Clone the repository
2. Copy .env.example to .env and fill in your values
3. Store your service account JSON key in 1Password as `onboarding-sa-key`
4. Make the script executable: `chmod +x scripts/onboard.sh`
5. Create department Google Groups in Admin Console before first run

## Usage
```bash
./scripts/onboard.sh new_hires.csv
```

## CSV Format
```
first_name,last_name,personal_email,department
Jane,Smith,jane@gmail.com,Engineering
Marcus,Rivera,marcus@gmail.com,Sales
```

Supported departments: Engineering, Sales, Marketing, HR

---

## Example Output
```
[2026-03-28T17:55:22Z] [INFO] Starting onboarding run | CSV: new_hires.csv
[2026-03-28T17:55:22Z] [INFO] --- Processing: Jeremy Cangiano (Engineering) ---
[2026-03-28T17:55:24Z] [SUCCESS] Created user jeremy.cangiano@cangianostudios.com
[2026-03-28T17:55:26Z] [SUCCESS] Added jeremy.cangiano@cangianostudios.com to eng@cangianostudios.com
[2026-03-28T17:55:27Z] [SUCCESS] Welcome email sent to jeremycangiano@gmail.com
[2026-03-28T17:55:27Z] [SUCCESS] === Completed onboarding for Jeremy Cangiano ===
[2026-03-28T17:55:27Z] [INFO] Run complete | Total: 1 | OK: 1 | Failed: 0
```

---

## Error Handling

| Scenario | Behavior |
|---|---|
| User already exists (409) | Log WARN, continue with group + email steps |
| Group doesn't exist (404) | Log ERROR, continue — user still created |
| Auth failure (403) | Log ERROR, skip entire hire row |
| Gmail send failure | Log WARN (non-fatal) — account still created |
| Unknown department | Log WARN, skip group assignment, continue |
| Re-running same CSV | Idempotent — warnings not errors, no duplicates |

The script exits with code 1 if any row failed, enabling cron jobs
or CI/CD pipelines to detect failures via exit code. Each run writes
a timestamped log file to logs/ for auditing.

---

## Security

- Service account JSON key is stored in 1Password, never on disk permanently
- The key is pulled into a temp file (chmod 600) at runtime and deleted
  automatically via `trap` when the script exits
- Credentials are loaded from .env (gitignored) — never hardcoded
- .env.example is committed with placeholder values only
- `changePasswordAtNextLogin: true` is always set — new hires must
  change their temp password on first login
- Service account has only the three OAuth2 scopes it needs — no extra GCP roles
- Passwords are SHA-1 hashed before being sent to the API
- Log files contain email addresses but never passwords

---

## Proposed Enhancements

- **Dry-run mode** — `--dry-run` flag to validate CSV without making API calls
- **Parallel processing** — use `xargs -P 4` to onboard multiple hires concurrently
- **Slack notification** — POST a summary to #it-ops when the run completes
- **Name collision handling** — append numeric suffix if username already exists
- **Token caching** — reuse the admin token across all rows instead of fetching per user