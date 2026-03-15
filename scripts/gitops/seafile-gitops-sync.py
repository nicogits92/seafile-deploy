#!/usr/bin/env python3
# =============================================================================
# seafile-gitops-sync.py
# =============================================================================
# Webhook listener for Gitea push events.
#
# On each push:
#   1. Verifies the Gitea HMAC-SHA256 webhook signature
#   2. Runs git pull in the local clone of the gitops repo
#   3. Compares the new .env against the live one
#   4. If .env changed: copies it to /opt/seafile/.env and runs update.sh --yes
#   5. If update.sh succeeded AND PORTAINER_STACK_WEBHOOK is set:
#      POSTs to that URL so Portainer redeploys the stack with the new env vars
#
# Portainer is notified by the VM, not by Gitea directly. This guarantees that
# Portainer never redeploys until after update.sh has finished writing config
# files and restarting containers — eliminating any race between the two.
#
# Installed to: /opt/seafile/seafile-gitops-sync.py
# Managed by:   seafile-gitops-sync.service (reads /opt/seafile/.env for config)
# =============================================================================

import fcntl
import hashlib
import hmac
import http.server
import logging
import os
import subprocess
import sys
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Config — all sourced from environment (injected by systemd EnvironmentFile)
# ---------------------------------------------------------------------------
WEBHOOK_SECRET      = os.environ.get('GITOPS_WEBHOOK_SECRET',      '')
CLONE_PATH          = os.environ.get('GITOPS_CLONE_PATH',          '/opt/seafile-gitops')
PORTAINER_WEBHOOK   = os.environ.get('PORTAINER_STACK_WEBHOOK', '')
ENV_DEST            = '/opt/seafile/.env'
UPDATE_SCRIPT       = '/opt/update.sh'
PORT                = int(os.environ.get('GITOPS_WEBHOOK_PORT', '9002'))
LOCK_FILE           = '/tmp/seafile-gitops.lock'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [GITOPS] %(levelname)s %(message)s',
    stream=sys.stdout
)
log = logging.getLogger()

# ---------------------------------------------------------------------------
# Sync logic
# ---------------------------------------------------------------------------

def file_hash(path):
    """MD5 of a file, or None if it does not exist."""
    try:
        with open(path, 'rb') as f:
            return hashlib.md5(f.read()).hexdigest()
    except FileNotFoundError:
        return None


def notify_portainer():
    """POST to the Portainer stack webhook URL to trigger a redeploy."""
    if not PORTAINER_WEBHOOK:
        return
    try:
        req = urllib.request.Request(PORTAINER_WEBHOOK, method='POST', data=b'')
        with urllib.request.urlopen(req, timeout=15) as resp:
            log.info(f'Portainer notified — HTTP {resp.status}')
    except urllib.error.URLError as e:
        log.warning(f'Portainer webhook call failed: {e}')
        log.warning('Seafile is running correctly. Update Portainer manually if env vars changed.')


def run_sync():
    """Pull repo, apply .env if changed, then notify Portainer. Lock prevents overlaps."""
    lock_fd = open(LOCK_FILE, 'w')
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.warning('Sync already in progress — skipping this webhook.')
        return

    try:
        env_in_repo = os.path.join(CLONE_PATH, '.env')
        old_hash    = file_hash(env_in_repo)

        # Pull latest from the gitops repo
        result = subprocess.run(
            ['git', 'pull'],
            cwd=CLONE_PATH,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            # Sanitize stderr to avoid leaking auth tokens from the remote URL
            stderr_clean = result.stderr.strip()
            if 'oauth2:' in stderr_clean:
                stderr_clean = '(authentication error — check GITOPS_TOKEN)'
            log.error(f'git pull failed: {stderr_clean}')
            return
        log.info(f'git pull: {result.stdout.strip()}')

        new_hash = file_hash(env_in_repo)

        if old_hash == new_hash:
            log.info('.env is unchanged — no action needed.')
            # Still notify Portainer if a compose-only change was pushed,
            # so that image tag bumps committed without .env changes still land.
            notify_portainer()
            return

        log.info('.env has changed — applying update.')

        # Copy new .env into place
        subprocess.run(['cp', env_in_repo, ENV_DEST], check=True)
        subprocess.run(['chmod', '600', ENV_DEST],    check=True)
        log.info(f'Copied new .env to {ENV_DEST}')

        # Run update.sh non-interactively
        log.info('Running update.sh --yes ...')
        result = subprocess.run(['bash', UPDATE_SCRIPT, '--yes'], timeout=600)
        if result.returncode != 0:
            log.error(f'update.sh exited with code {result.returncode}')
            log.error('Portainer will NOT be notified — resolve the update.sh error first.')
            return

        log.info('update.sh completed successfully.')

        # Notify Portainer only after update.sh has fully finished
        notify_portainer()

    except Exception as e:
        log.error(f'Unexpected error during sync: {e}')
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class WebhookHandler(http.server.BaseHTTPRequestHandler):

    def do_POST(self):
        if self.path != '/webhook':
            self._respond(404)
            return

        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length)

        # Verify Gitea HMAC-SHA256 signature
        if WEBHOOK_SECRET:
            sig      = self.headers.get('X-Gitea-Signature', '')
            expected = hmac.new(
                WEBHOOK_SECRET.encode(), body, hashlib.sha256
            ).hexdigest()
            if not hmac.compare_digest(sig, expected):
                log.warning('Webhook signature mismatch — request rejected.')
                self._respond(403)
                return

        # Acknowledge immediately so Gitea does not time out
        self._respond(200)

        # Run sync in a child process so we do not block the HTTP server
        subprocess.Popen([sys.executable, __file__, '--run-sync'])

    def _respond(self, code):
        self.send_response(code)
        self.end_headers()

    def log_message(self, fmt, *args):
        log.info(fmt % args)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--run-sync':
        run_sync()
    else:
        log.info(f'GitOps webhook listener starting on :{PORT}')
        log.info(f'Gitops repo clone: {CLONE_PATH}')
        log.info(f'Webhook endpoint:  POST http://THIS_HOST_IP:{PORT}/webhook')
        if PORTAINER_WEBHOOK:
            log.info(f'Portainer webhook: configured — will notify after each successful update')
        else:
            log.info(f'Portainer webhook: not configured — set PORTAINER_STACK_WEBHOOK to enable')
        server = http.server.HTTPServer(('0.0.0.0', PORT), WebhookHandler)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            log.info('Listener stopped.')
