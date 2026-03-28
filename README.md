# Google Workspace Onboarding Automation

A Bash script that automates the end-to-end onboarding of new employees 
into Google Workspace for cangianostudios.com.

## What it does

- Reads a CSV file of new hires
- Creates a Google Workspace account for each employee
- Adds each employee to their department Google Group
- Sends a personalized welcome email to their personal address

## Requirements

- Google Cloud project with Admin SDK and Gmail API enabled
- Service Account with Domain-Wide Delegation configured
- 1Password CLI installed and authenticated
- jq installed (brew install jq)

## Setup

1. Clone the repository
2. Copy .env.example to .env and fill in your values
3. Store your service account JSON key in 1Password as onboarding-sa-key
4. Make the script executable: chmod +x scripts/onboard.sh

## Usage

./scripts/onboard.sh new_hires.csv

## CSV Format

first_name,last_name,personal_email,department
Jane,Smith,jane@gmail.com,Engineering

## Security

- Credentials are stored in .env (gitignored)
- Service account key is pulled from 1Password at runtime
- Temp files are deleted automatically after each run
