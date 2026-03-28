#!/usr/bin/env bash
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
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
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
      printf '%s' "$email"
      ;;
    409)
      warn "User ${email} already exists — skipping"
      printf '%s' "$email"
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
