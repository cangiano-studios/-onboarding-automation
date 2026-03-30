#!/usr/bin/env bash
# =============================================================================
# onboard.sh — Google Workspace Employee Onboarding Automation
# =============================================================================
# Created:     March 28, 2026
# Author:      Jeremy Cangiano
# Domain:      cangianostudios.com
#
# Description:
#   Automates end-to-end onboarding of new employees into Google Workspace.
#   Reads a CSV of new hires, creates Workspace accounts, adds users to
#   department Google Groups, and sends a personalized welcome email.
#
# AI Assistance:
#   Built with the help of Claude Sonnet 4.6 (Anthropic). Claude was used for
#   error analysis, remediation guidance, and testing functionality
#   throughout development. Claude also assisted in formulating
#   documentation, organizing thoughts, and structuring the project write-up and README.
#
# Usage:
#   ./scripts/onboard.sh new_hires.csv
# =============================================================================
set -euo pipefail

set -a
source .env
set +a
# Pull SA key from 1Password
SA_KEY_TMP=$(mktemp)
chmod 600 "$SA_KEY_TMP"
op document get "onboarding-sa-key" > "$SA_KEY_TMP"
export GOOGLE_SA_KEY_FILE="$SA_KEY_TMP"

# Delete the temp file when script exits
trap 'rm -f "$SA_KEY_TMP"' EXIT
# Log file location
LOG_FILE="logs/onboard_$(date +%Y%m%d_%H%M%S).log"
mkdir -p logs

# Logging helper
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}

info()    { log INFO    "$@"; }
success() { log SUCCESS "$@"; }
warn()    { log WARN    "$@"; }
error()   { log ERROR   "$@"; }

# Department to Google Group mapping
dept_to_group() {
  local dept
  dept="$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$dept" in
    engineering|eng) echo "eng@cangianostudios.com" ;;
    sales)           echo "sales@cangianostudios.com" ;;
    marketing)       echo "marketing@cangianostudios.com" ;;
    hr)              echo "hr@cangianostudios.com" ;;
    *)
      warn "Unknown department '${dept}' — no group will be assigned"
      echo ""
      ;;
  esac
}

# OAuth2 access token via Service Account
get_access_token() {
  local scope="$1"
  local sub="$2"

  # Read SA fields from JSON key file
  local sa_email private_key
  sa_email="$(jq -r '.client_email' "$GOOGLE_SA_KEY_FILE")"
  private_key="$(jq -r '.private_key' "$GOOGLE_SA_KEY_FILE")"

  # Build timestamps
  local now exp
  now="$(date +%s)"
  exp=$((now + 3600))

  # base64url encode helper
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

  # Build JWT header and payload
  local header payload
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iss":"%s","scope":"%s","aud":"https://oauth2.googleapis.com/token","exp":%d,"iat":%d,"sub":"%s"}' \
    "$sa_email" "$scope" "$exp" "$now" "$sub" | b64url)"

  # Sign with private key
  local tmp_key sig_input signature
  tmp_key="$(mktemp)"
  chmod 600 "$tmp_key"
  printf '%s' "$private_key" > "$tmp_key"
  sig_input="${header}.${payload}"
  signature="$(printf '%s' "$sig_input" \
    | openssl dgst -sha256 -sign "$tmp_key" \
    | b64url)"
  rm -f "$tmp_key"

  # Exchange JWT for access token
  local jwt response token
  jwt="${sig_input}.${signature}"
  response="$(curl -s -X POST "https://oauth2.googleapis.com/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=${jwt}")"

  token="$(printf '%s' "$response" | jq -r '.access_token // empty')"

  if [[ -z "$token" ]]; then
    error "Failed to get token: $(printf '%s' "$response" | jq -r '.error_description // .')"
    return 1
  fi
  printf '%s' "$token"
}
# Create a Google Workspace user
create_user() {
  local token="$1"
  local first="$2" last="$3"
  local email="$(echo "${first}.${last}" | tr '[:upper:]' '[:lower:]')@cangianostudios.com"

  info "Creating user: ${email}"

local hashed_pass
hashed_pass="$(echo -n "$DEFAULT_PASSWORD" | openssl dgst -sha1)"

local payload
payload="$(jq -cn \
  --arg email "$email" \
  --arg first "$first" \
  --arg last  "$last" \
  --arg pass  "$hashed_pass" \
  '{
    primaryEmail: $email,
    name: { givenName: $first, familyName: $last },
    password: $pass,
    hashFunction: "SHA-1",
    changePasswordAtNextLogin: true,
    orgUnitPath: "/"
  }')"

  local http_code response
  response="$(curl -s -w '\n%{http_code}' \
    -X POST "https://admin.googleapis.com/admin/directory/v1/users" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload")"

  http_code="$(printf '%s' "$response" | tail -n1)"
  response="$(printf '%s' "$response" | sed '$d')"

  case "$http_code" in
    200|201)
      success "Created user ${email}"
      echo "$email"
      ;;
    409)
      warn "User ${email} already exists — skipping"
      echo "$email"
      ;;
    *)
      error "Failed to create ${email} (HTTP ${http_code}): $(printf '%s' "$response")"
      return 1
      ;;
  esac
}
dir_token="$(get_access_token \
  "https://www.googleapis.com/auth/admin.directory.user" \
  "jeremy@cangianostudios.com")"
create_user "$dir_token" "Jane" "Smith"

# Add user to a Google Group
add_to_group() {
  local token="$1"
  local user_email="$2"
  local group_email="$3"

  if [[ -z "$group_email" ]]; then
    warn "No group mapped for ${user_email} — skipping group assignment"
    return 0
  fi

  info "Adding ${user_email} to group ${group_email}"

  local payload
  payload="$(jq -cn --arg email "$user_email" '{ email: $email, role: "MEMBER" }')"

  local http_code response
  response="$(curl -s -w '\n%{http_code}' \
    -X POST "https://admin.googleapis.com/admin/directory/v1/groups/${group_email}/members" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload")"

  http_code="$(printf '%s' "$response" | tail -n1)"
  response="$(printf '%s' "$response" | sed '$d')"

  case "$http_code" in
    200|201)
      success "Added ${user_email} to ${group_email}"
      ;;
    409)
      warn "${user_email} is already a member of ${group_email}"
      ;;
    404)
      error "Group ${group_email} not found — does it exist in Admin Console?"
      return 1
      ;;
    *)
      error "Failed to add ${user_email} to ${group_email} (HTTP ${http_code}): $(printf '%s' "$response")"
      return 1
      ;;
  esac
}

# Send welcome email via Gmail API
send_welcome_email() {
  local token="$1"
  local user_email="$2"
  local first="$3"
  local dept="$4"
  local personal_email="$5"

  info "Sending welcome email to ${personal_email}"

  # Build the email body
  local subject="Welcome to Cangiano Studios, ${first}!"
  local body
  body="Hi ${first},

Welcome to Cangiano Studios! Your Google Workspace account is ready.

  Corporate email : ${user_email}
  Department      : ${dept}
  Temp password   : ${DEFAULT_PASSWORD}

IMPORTANT: Please sign in at https://accounts.google.com and change
your password immediately. You will be prompted on first login.

Useful links:
  - Google Drive    : https://drive.google.com
  - Google Calendar : https://calendar.google.com
  - IT Help Desk    : jeremy@cangianostudios.com

Welcome aboard!
The IT Team at Cangiano Studios"

  # Build RFC 2822 MIME message
  local raw_mime
  raw_mime="From: IT Team <${user_email}>
To: ${personal_email}
Cc: ${user_email}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${body}"

  # base64url encode
  local encoded
  encoded="$(printf '%s' "$raw_mime" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"

  local payload
  payload="$(jq -cn --arg raw "$encoded" '{raw: $raw}')"

  local http_code response
  response="$(curl -s -w '\n%{http_code}' \
    -X POST "https://gmail.googleapis.com/gmail/v1/users/jeremy@cangianostudios.com/messages/send" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload")"

  http_code="$(printf '%s' "$response" | tail -n1)"
  response="$(printf '%s' "$response" | sed '$d')"

  case "$http_code" in
    200|201)
      success "Welcome email sent to ${personal_email}"
      ;;
    *)
      warn "Failed to send welcome email (HTTP ${http_code}): $(printf '%s' "$response")"
      ;;
  esac
}

# Process one hire — wraps all steps
process_hire() {
  local first="$1" last="$2" personal_email="$3" dept="$4"

  info "--- Processing: ${first} ${last} (${dept}) ---"

  # Get Admin SDK token
  local dir_token
  dir_token="$(get_access_token \
    "https://www.googleapis.com/auth/admin.directory.user https://www.googleapis.com/auth/admin.directory.group.member" \
    "jeremy@cangianostudios.com")" || {
    error "Could not get directory token for ${first} ${last} — skipping"
    return 1
  }

  # Create user
  local user_email
  user_email="$(create_user "$dir_token" "$first" "$last")" || return 1

  # Add to department group
  local group
  group="$(dept_to_group "$dept")"
  add_to_group "$dir_token" "$user_email" "$group" || true

  # Get Gmail token impersonating the new hire
  local gmail_token
  gmail_token="$(get_access_token \
    "https://www.googleapis.com/auth/gmail.send" \
  "jeremy@cangianostudios.com")" || {
    warn "Could not get Gmail token — skipping welcome email"
    return 0
  }

  # Send welcome email
  send_welcome_email "$gmail_token" "$user_email" "$first" "$dept" "$personal_email" || true

  success "=== Completed onboarding for ${first} ${last} ==="
}

# Main — read CSV and process each row
main() {
  local csv_file="$1"
  info "Starting onboarding run | CSV: ${csv_file}"
  info "Log file: ${LOG_FILE}"

  local total=0 ok=0 failed=0

  while IFS=',' read -r first last personal_email dept _rest; do
    # Skip blank lines and header
    [[ -z "$first" || "$first" == "first_name" ]] && continue

    # Trim whitespace and quotes
    first="${first//\"/}"
    last="${last//\"/}"
    personal_email="${personal_email//\"/}"
    dept="${dept//\"/}"

    total=$((total + 1))

    if process_hire "$first" "$last" "$personal_email" "$dept"; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
      error "Failed to onboard ${first} ${last}"
    fi

  done < "$csv_file"

  info "================================================"
  info "Run complete | Total: ${total} | OK: ${ok} | Failed: ${failed}"
  info "================================================"

  [[ $failed -eq 0 ]]
}

main "$@"
