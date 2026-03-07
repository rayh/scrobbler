#!/bin/bash

# Set Apple credentials in AWS Secrets Manager
# Usage: ./set-apple-credentials.sh <team_id> <key_id> <path_to_p8_file>

TEAM_ID=$1
KEY_ID=$2
P8_FILE=$3

if [ -z "$TEAM_ID" ] || [ -z "$KEY_ID" ] || [ -z "$P8_FILE" ]; then
  echo "Usage: ./set-apple-credentials.sh <team_id> <key_id> <path_to_p8_file>"
  echo "Example: ./set-apple-credentials.sh A8G8PC6Q6K 2TFR78HSZW ~/Downloads/AuthKey_2TFR78HSZW.p8"
  exit 1
fi

if [ ! -f "$P8_FILE" ]; then
  echo "Error: File not found: $P8_FILE"
  exit 1
fi

PRIVATE_KEY=$(cat "$P8_FILE")

SECRET_VALUE=$(cat <<EOF
{
  "teamId": "$TEAM_ID",
  "keyId": "$KEY_ID",
  "privateKey": "$PRIVATE_KEY"
}
EOF
)

aws secretsmanager create-secret \
  --name scrobbled-at/apple-credentials \
  --secret-string "$SECRET_VALUE" \
  --profile scrobbler \
  --region eu-west-1 \
  2>/dev/null || \
aws secretsmanager update-secret \
  --secret-id scrobbled-at/apple-credentials \
  --secret-string "$SECRET_VALUE" \
  --profile scrobbler \
  --region eu-west-1

echo "✅ Apple credentials stored in Secrets Manager"
echo "   Team ID: $TEAM_ID"
echo "   Key ID: $KEY_ID"
