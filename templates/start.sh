#!/usr/bin/env bash
# Starts the app on localhost only. The VPN's https address is the one way in
# from other devices; see docs/local-app-pattern.md.
#
# Copy to bin/start in the app, adjust APP_NAME and the last line, then
# `chmod +x bin/start`.
set -euo pipefail

APP_NAME="myapp"
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME/env"

cd "$(dirname "$0")/.."

# Settings and secrets live outside the repo, one KEY=value per line.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
else
  echo "No settings at $ENV_FILE; copy templates/app.env.example there." >&2
  exit 1
fi

: "${PORT:?set PORT in $ENV_FILE}"

# Rails shown; for anything else, bind to 127.0.0.1:$PORT the same way.
exec bin/rails server --binding 127.0.0.1 --port "$PORT"
