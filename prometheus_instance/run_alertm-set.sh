#!/bin/bash

set -eu


# Enter here your values 
(
  . <(cat <<'EOF'
PASS_AUTH='...'
AUTH_UNAME='...'
SMTP='...'
EMAIL='...'
EOF
  )
sudo env PASS_AUTH="$PASS_AUTH" AUTH_UNAME="$AUTH_UNAME" SMTP="$SMTP" EMAIL="$EMAIL" dpkg -i prometheus-alertm-settings_0.1-3_all.deb
)

