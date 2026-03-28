# Pull SA key from 1Password
SA_KEY_TMP=$(mktemp)
chmod 600 "$SA_KEY_TMP"
op document get "onboarding-sa-key" > "$SA_KEY_TMP"
export GOOGLE_SA_KEY_FILE="$SA_KEY_TMP"

# Delete the temp file when script exits
trap 'rm -f "$SA_KEY_TMP"' EXIT
