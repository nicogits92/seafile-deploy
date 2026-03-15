# =============================================================================
# gunicorn.conf.py — Seahub WSGI server settings
# =============================================================================
# Written by:  seafile-config-fixes.sh / update.sh
# Deployed to: $SEAFILE_VOLUME/seafile/conf/gunicorn.conf.py
#
# REFERENCE FILE — see seahub_settings.py header for editing note.
#
# Non-standard vs default Seafile gunicorn.conf.py:
#   - timeout raised to 1200s (default: 30s). Without this, uploading large
#     files through the web UI causes a 502 from gunicorn before the transfer
#     completes. Caddy and NPM have their own timeouts set independently.
#   - forwarder_headers includes REMOTE_USER — required if using SSO via a
#     reverse proxy that sets this header (e.g. Authentik, Authelia).
# =============================================================================

import os

daemon = True
workers = 5

# Default localhost:8000
bind = "127.0.0.1:8000"

# Pid
pids_dir = '/opt/seafile/pids'
pidfile = os.path.join(pids_dir, 'seahub.pid')

# Long timeout needed for large file uploads (default 30s is too short)
timeout = 1200
limit_request_line = 8190

# For forwarder headers
forwarder_headers = 'SCRIPT_NAME,PATH_INFO,REMOTE_USER'
