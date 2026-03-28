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
info "Logging is working"
