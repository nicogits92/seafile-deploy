#!/bin/bash
# =============================================================================
# seafile-config-server.sh — Local git HTTP server for Portainer integration
# =============================================================================
# Serves the config history git repo over HTTP so Portainer can use it as a
# git-based stack source. Portainer pulls docker-compose.yml and .env from
# this server automatically on each webhook trigger.
#
# Only active when PORTAINER_MANAGED=true.
# Listens on CONFIG_GIT_PORT (default 9418).
#
# Deployed to: /opt/seafile/seafile-config-server.sh
# Managed by:  seafile-config-server.service (systemd)
# =============================================================================

set -euo pipefail

REPO_DIR="/opt/seafile/.config-history"
ENV_FILE="/opt/seafile/.env"

# Read port from .env
PORT=9418
if [ -f "$ENV_FILE" ]; then
  _port=$(grep "^CONFIG_GIT_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
  PORT="${_port:-9418}"
fi

# Ensure repo exists and server-info is current
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "ERROR: Config history repo not found at $REPO_DIR"
  exit 1
fi
cd "$REPO_DIR"
git update-server-info 2>/dev/null || true

echo "Starting config git server on port $PORT (serving $REPO_DIR)"

# Minimal Python HTTP server — serves the repo for dumb HTTP git clone
exec python3 -c "
import http.server, os, sys

os.chdir('$REPO_DIR')
PORT = $PORT

class GitHTTPHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Log to stdout for journalctl
        sys.stdout.write('[CONFIG-GIT] %s\n' % (fmt % args))
        sys.stdout.flush()

    def do_GET(self):
        # Only serve .git/ contents and root files (.env, docker-compose.yml)
        if self.path.startswith('/.git/') or self.path in ('/.env', '/docker-compose.yml', '/'):
            super().do_GET()
        else:
            self.send_error(404)

    def do_POST(self):
        self.send_error(405)

print(f'Config git server listening on port {PORT}', flush=True)
http.server.HTTPServer(('0.0.0.0', PORT), GitHTTPHandler).serve_forever()
"
