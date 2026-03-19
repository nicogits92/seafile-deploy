#!/usr/bin/env python3
# =============================================================================
# seafile-config-ui.py — Web configuration panel for seafile-deploy
# =============================================================================
# Lightweight HTTP server serving a browser-based .env editor.
# Runs as a systemd service, proxied through Caddy at /admin/config.
#
# Installed to: /opt/seafile/seafile-config-ui.py
# HTML served:  /opt/seafile/config-ui.html
# Managed by:   seafile-config-ui.service (systemd)
# =============================================================================

import base64
import fcntl
import hashlib
import hmac
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time

PORT = 9443
ENV_FILE = '/opt/seafile/.env'
HTML_FILE = '/opt/seafile/config-ui.html'
SECRETS_FILE = '/opt/seafile/.secrets'

# ---------------------------------------------------------------------------
# .env reader/writer (same safe parser as shared-lib.sh)
# ---------------------------------------------------------------------------

ENV_LOCK = ENV_FILE + '.lock'


def _lock(exclusive=False):
    """Acquire a file lock. Returns the lock file descriptor."""
    fd = open(ENV_LOCK, 'w')
    fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
    return fd


def _unlock(fd):
    """Release a file lock."""
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()


def load_env(path=ENV_FILE):
    env = {}
    if not os.path.isfile(path):
        return env
    fd = _lock(exclusive=False)
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, val = line.split('=', 1)
                key = key.strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                elif val.startswith("'") and val.endswith("'"):
                    val = val[1:-1]
                env[key] = val
    finally:
        _unlock(fd)
    return env


def _env_quote(val):
    """Quote a value for safe .env writing. Escapes special characters."""
    needs_quote = any(c in val for c in ' #;$`"\\')
    if not needs_quote:
        return val
    # Escape backslashes first, then double quotes, $, and backticks
    val = val.replace('\\', '\\\\')
    val = val.replace('"', '\\"')
    val = val.replace('$', '\\$')
    val = val.replace('`', '\\`')
    return f'"{val}"'


def save_env(updates, path=ENV_FILE):
    """Update specific keys in .env, preserving comments and structure."""
    if not os.path.isfile(path):
        return False
    fd = _lock(exclusive=True)
    try:
        with open(path) as f:
            lines = f.readlines()
        keys_written = set()
        out = []
        for line in lines:
            stripped = line.strip()
            if stripped and not stripped.startswith('#') and '=' in stripped:
                key = stripped.split('=', 1)[0].strip()
                if key in updates:
                    out.append(f'{key}={_env_quote(updates[key])}\n')
                    keys_written.add(key)
                    continue
            out.append(line)
        # Append any new keys not already in the file
        for k, v in updates.items():
            if k not in keys_written:
                out.append(f'{k}={_env_quote(v)}\n')
        with open(path, 'w') as f:
            f.writelines(out)
        os.chmod(path, 0o600)
    finally:
        _unlock(fd)
    return True


# ---------------------------------------------------------------------------
# Container status
# ---------------------------------------------------------------------------

def get_container_status():
    containers = []
    try:
        result = subprocess.run(
            ['docker', 'ps', '-a', '--format', '{{.Names}}\t{{.Status}}\t{{.Image}}'],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.strip().split('\n'):
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) >= 3:
                name = parts[0]
                status_raw = parts[1]
                image = parts[2]
                running = 'Up' in status_raw
                uptime = ''
                if running:
                    m = re.search(r'Up\s+(.+)', status_raw)
                    if m:
                        uptime = m.group(1)
                containers.append({
                    'name': name,
                    'running': running,
                    'uptime': uptime,
                    'image': image.split(':')[-1] if ':' in image else image
                })
    except Exception:
        pass
    return containers


# ---------------------------------------------------------------------------
# Config apply (runs seafile-config-fixes.sh)
# ---------------------------------------------------------------------------

_apply_lock = threading.Lock()
_apply_status = {'running': False, 'last_result': None, 'last_time': None}

# Operations runner — shared state for background operations
_ops_status = {}


def _notify_portainer():
    """Ping Portainer stack webhook to trigger a redeploy."""
    env = load_env()
    webhook = env.get('PORTAINER_STACK_WEBHOOK', '')
    if not webhook:
        return 'no_webhook'
    try:
        import urllib.request
        req = urllib.request.Request(webhook, method='POST', data=b'')
        urllib.request.urlopen(req, timeout=15)
        return 'ok'
    except Exception as e:
        return f'error: {e}'


def apply_config():
    """Run config-fixes in background thread."""
    if _apply_status['running']:
        return False
    env = load_env()
    portainer_managed = env.get('PORTAINER_MANAGED', 'false') == 'true'

    def _run():
        _apply_status['running'] = True
        try:
            # In Portainer mode: write config files but skip restart
            # Then ping Portainer to handle the lifecycle
            cmd = ['bash', '/opt/seafile-config-fixes.sh', '--yes']
            if portainer_managed:
                cmd.append('--no-restart')
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if result.returncode == 0:
                if portainer_managed:
                    pw = _notify_portainer()
                    _apply_status['last_result'] = f'success (portainer: {pw})'
                else:
                    _apply_status['last_result'] = 'success'
            else:
                _apply_status['last_result'] = 'error'
        except Exception as e:
            _apply_status['last_result'] = f'error: {e}'
        _apply_status['last_time'] = time.strftime('%Y-%m-%d %H:%M:%S')
        _apply_status['running'] = False
    threading.Thread(target=_run, daemon=True).start()
    return True


def run_operation(op_name, cmd, timeout=600):
    """Run an operation (update, gc, backup, apt) in background."""
    key = op_name
    if key in _ops_status and _ops_status[key].get('running'):
        return False
    _ops_status[key] = {'running': True, 'result': None, 'time': None, 'log': ''}

    def _run():
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout
            )
            _ops_status[key]['log'] = (result.stdout or '') + (result.stderr or '')
            _ops_status[key]['result'] = 'success' if result.returncode == 0 else 'error'
        except subprocess.TimeoutExpired:
            _ops_status[key]['result'] = 'timeout'
        except Exception as e:
            _ops_status[key]['result'] = f'error: {e}'
        _ops_status[key]['time'] = time.strftime('%Y-%m-%d %H:%M:%S')
        _ops_status[key]['running'] = False
    threading.Thread(target=_run, daemon=True).start()
    return True


# ---------------------------------------------------------------------------
# Schedule conversion (human-readable ↔ cron)
# ---------------------------------------------------------------------------

DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']


def cron_to_human(cron_str):
    """Convert cron string to {frequency, time, day} dict."""
    parts = cron_str.strip().split()
    if len(parts) != 5:
        return {'frequency': 'daily', 'time': '02:00', 'day': 0}
    minute, hour, dom, mon, dow = parts
    if hour == '*' or '/' in hour:
        return {'frequency': 'hourly', 'time': '00:00', 'day': 0}
    try:
        time_str = f'{int(hour):02d}:{int(minute):02d}'
    except ValueError:
        return {'frequency': 'daily', 'time': '02:00', 'day': 0}
    if dow != '*' and dom == '*':
        try:
            return {'frequency': 'weekly', 'time': time_str, 'day': int(dow)}
        except ValueError:
            return {'frequency': 'weekly', 'time': time_str, 'day': 0}
    return {'frequency': 'daily', 'time': time_str, 'day': 0}


def human_to_cron(freq, time_str, day=0):
    """Convert frequency/time/day to cron string."""
    try:
        h, m = time_str.split(':')
        h = str(int(h))  # strip leading zeros: '02' -> '2'
        m = str(int(m))  # strip leading zeros: '00' -> '0'
    except ValueError:
        h, m = '2', '0'
    if freq == 'hourly':
        return '0 * * * *'
    if freq == 'weekly':
        return f'{m} {h} * * {day}'
    return f'{m} {h} * * *'


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

def check_auth(handler):
    """Verify HTTP Basic Auth against CONFIG_UI_PASSWORD."""
    env = load_env()
    password = env.get('CONFIG_UI_PASSWORD', '')
    if not password:
        return True  # No password set = allow (first-run)
    auth_header = handler.headers.get('Authorization', '')
    if not auth_header.startswith('Basic '):
        return False
    try:
        decoded = base64.b64decode(auth_header[6:]).decode()
        _, pw = decoded.split(':', 1)
        return hmac.compare_digest(pw, password)
    except Exception:
        return False


def send_auth_required(handler):
    handler.send_response(401)
    handler.send_header('WWW-Authenticate', 'Basic realm="Seafile Configuration"')
    handler.send_header('Content-Type', 'text/plain')
    handler.end_headers()
    handler.wfile.write(b'Authentication required')


# ---------------------------------------------------------------------------
# Sensitive keys (masked in API responses)
# ---------------------------------------------------------------------------

SENSITIVE_KEYS = {
    'SEAFILE_MYSQL_DB_PASSWORD', 'INIT_SEAFILE_MYSQL_ROOT_PASSWORD',
    'REDIS_PASSWORD', 'SMTP_PASSWORD', 'LDAP_BIND_PASSWORD',
    'JWT_PRIVATE_KEY', 'COLLABORA_ADMIN_PASSWORD', 'ONLYOFFICE_JWT_SECRET',
    'GITOPS_TOKEN', 'GITOPS_WEBHOOK_SECRET', 'CONFIG_UI_PASSWORD',
    'SMB_PASSWORD', 'ISCSI_CHAP_PASSWORD', 'BACKUP_SMB_PASSWORD',
    'INIT_SEAFILE_ADMIN_PASSWORD',
}


def mask_env(env):
    """Return env dict with sensitive values masked."""
    masked = {}
    for k, v in env.items():
        if k in SENSITIVE_KEYS and v:
            masked[k] = '••••••••'
        else:
            masked[k] = v
    return masked


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class ConfigHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        if not check_auth(self):
            return send_auth_required(self)

        if self.path == '/' or self.path == '/index.html':
            self._serve_html()
        elif self.path == '/api/env':
            self._json_response(mask_env(load_env()))
        elif self.path == '/api/status':
            self._json_response({
                'containers': get_container_status(),
                'apply': _apply_status
            })
        elif self.path == '/api/schedules':
            env = load_env()
            self._json_response({
                'backup': cron_to_human(env.get('BACKUP_SCHEDULE', '0 2 * * *')),
                'gc': cron_to_human(env.get('GC_SCHEDULE', '0 3 * * 0')),
            })
        elif self.path == '/api/operations':
            self._json_response(_ops_status)
        elif self.path == '/api/branding':
            env = load_env()
            custom_dir = os.path.join(env.get('SEAFILE_VOLUME', '/opt/seafile-data'),
                                      'seahub', 'media', 'custom')
            assets = {}
            for name in os.listdir(custom_dir) if os.path.isdir(custom_dir) else []:
                fpath = os.path.join(custom_dir, name)
                if os.path.isfile(fpath):
                    assets[name] = {
                        'size': os.path.getsize(fpath),
                        'modified': os.path.getmtime(fpath)
                    }
            # Read current deploy version
            deploy_version = 'unknown'
            if os.path.isfile('/opt/seafile-deploy.sh'):
                try:
                    with open('/opt/seafile-deploy.sh', 'r') as f:
                        for line in f:
                            if line.startswith('DEPLOY_VERSION='):
                                deploy_version = line.split('=', 1)[1].strip().strip('"')
                                break
                except Exception:
                    pass
            self._json_response({
                'assets': assets,
                'custom_dir': custom_dir,
                'deploy_version': deploy_version,
            })
        else:
            self.send_error(404)

    def do_POST(self):
        if not check_auth(self):
            return send_auth_required(self)

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        content_type = self.headers.get('Content-Type', 'application/json')

        if self.path == '/api/env':
            try:
                data = json.loads(body)
                updates = data.get('updates', {})
                # Convert schedule fields to cron
                for sched_key, env_key in [('backup_schedule', 'BACKUP_SCHEDULE'), ('gc_schedule', 'GC_SCHEDULE')]:
                    if sched_key in data:
                        s = data[sched_key]
                        updates[env_key] = human_to_cron(s.get('frequency', 'daily'), s.get('time', '02:00'), s.get('day', 0))
                if not updates:
                    self._json_response({'error': 'No updates provided'}, 400)
                    return
                # Compute diff
                current = load_env()
                diff = []
                for k, v in updates.items():
                    old = current.get(k, '')
                    if old != v:
                        display_old = '••••••••' if k in SENSITIVE_KEYS and old else old
                        display_new = '••••••••' if k in SENSITIVE_KEYS and v else v
                        diff.append({'key': k, 'old': display_old, 'new': display_new})
                if not diff:
                    self._json_response({'status': 'no_changes', 'diff': []})
                    return
                # Check if this is a preview or apply
                if data.get('preview', False):
                    self._json_response({'status': 'preview', 'diff': diff})
                    return
                # Write and apply
                if not save_env(updates):
                    self._json_response({'error': 'Failed to write .env'}, 500)
                    return
                apply_config()
                self._json_response({'status': 'applied', 'diff': diff})
            except json.JSONDecodeError:
                self._json_response({'error': 'Invalid JSON'}, 400)

        elif self.path == '/api/apply':
            if apply_config():
                self._json_response({'status': 'started'})
            else:
                self._json_response({'status': 'already_running'}, 409)

        elif self.path == '/api/operations':
            try:
                data = json.loads(body)
                op = data.get('operation', '')
                env = load_env()
                ops_map = {
                    'update': ['bash', '/opt/update.sh', '--yes'],
                    'gc': ['docker', 'exec', 'seafile', '/scripts/gc.sh'] +
                          (['-r'] if env.get('GC_REMOVE_DELETED', 'true') == 'true' else []),
                    'backup': ['bash', '/opt/seafile-backup.sh'],
                    'apt': ['bash', '-c', 'apt-get update -qq && apt-get upgrade -y -qq'],
                }
                if op not in ops_map:
                    self._json_response({'error': f'Unknown operation: {op}'}, 400)
                    return
                if run_operation(op, ops_map[op]):
                    self._json_response({'status': 'started', 'operation': op})
                else:
                    self._json_response({'status': 'already_running', 'operation': op}, 409)
            except json.JSONDecodeError:
                self._json_response({'error': 'Invalid JSON'}, 400)

        elif self.path == '/api/upload/branding':
            self._handle_upload_branding(body, content_type)

        elif self.path == '/api/upload/deploy-script':
            self._handle_upload_deploy(body)

        elif self.path == '/api/self-update':
            cmd = ['bash', '/opt/seafile-deploy.sh', '--extract-scripts', '/tmp/_ui_update_staging']
            try:
                subprocess.run(cmd, capture_output=True, timeout=30)
            except Exception as e:
                self._json_response({'error': str(e)}, 500)
                return
            # Apply updates using the same logic as CLI self-update
            file_map = {
                'seafile-config-fixes.sh': '/opt/seafile-config-fixes.sh',
                'update.sh': '/opt/update.sh',
                'seafile-cli.sh': '/usr/local/bin/seafile',
                'seafile-env-sync.sh': '/opt/seafile/seafile-env-sync.sh',
                'seafile-config-ui.py': '/opt/seafile/seafile-config-ui.py',
                'config-ui.html': '/opt/seafile/config-ui.html',
                'seafile-config-server.sh': '/opt/seafile/seafile-config-server.sh',
                'seafile-storage-sync.sh': '/opt/seafile/seafile-storage-sync.sh',
                'seafile-recovery-finalize.sh': '/opt/seafile/seafile-recovery-finalize.sh',
            }
            staging = '/tmp/_ui_update_staging'
            changed = []
            import filecmp
            backup_dir = f'/opt/seafile/.script-backups/{time.strftime("%Y-%m-%d_%H%M%S")}'
            os.makedirs(backup_dir, exist_ok=True)
            for name, dest in file_map.items():
                src = os.path.join(staging, name)
                if os.path.isfile(src) and os.path.getsize(src) > 0:
                    if not os.path.isfile(dest) or not filecmp.cmp(src, dest, shallow=False):
                        if os.path.isfile(dest):
                            import shutil
                            shutil.copy2(dest, os.path.join(backup_dir, name))
                        shutil.copy2(src, dest)
                        os.chmod(dest, 0o755)
                        changed.append(name)
            # Cleanup staging
            import shutil
            shutil.rmtree(staging, ignore_errors=True)
            # Restart management services
            subprocess.run(['systemctl', 'restart', 'seafile-env-sync'], capture_output=True)
            self._json_response({
                'status': 'updated',
                'changed': changed,
                'backup': backup_dir
            })

        else:
            self.send_error(404)

    def _handle_upload_branding(self, body, content_type):
        """Handle branding asset upload (logo, favicon, login background)."""
        env = load_env()
        custom_dir = os.path.join(env.get('SEAFILE_VOLUME', '/opt/seafile-data'),
                                  'seahub', 'media', 'custom')
        os.makedirs(custom_dir, exist_ok=True)

        # Parse multipart form data
        file_data, filename, form_fields = self._parse_multipart(body, content_type)
        if file_data is None:
            self._json_response({'error': 'No file in upload'}, 400)
            return

        asset_type = form_fields.get('type', 'logo')
        allowed_types = {
            'logo': {'exts': ['.png', '.jpg', '.jpeg', '.svg', '.gif'], 'env_key': 'LOGO_PATH'},
            'favicon': {'exts': ['.png', '.ico', '.svg'], 'env_key': 'FAVICON_PATH'},
            'login_bg': {'exts': ['.png', '.jpg', '.jpeg', '.svg', '.webp'], 'env_key': 'LOGIN_BG_IMAGE_PATH'},
            'css': {'exts': ['.css'], 'env_key': 'BRANDING_CSS'},
        }

        if asset_type not in allowed_types:
            self._json_response({'error': f'Unknown asset type: {asset_type}'}, 400)
            return

        info = allowed_types[asset_type]
        ext = os.path.splitext(filename)[1].lower()
        if ext not in info['exts']:
            self._json_response({'error': f'Invalid file type {ext} for {asset_type}'}, 400)
            return

        # Sanitize filename: asset_type + original extension
        safe_name = f'{asset_type}{ext}'
        dest_path = os.path.join(custom_dir, safe_name)

        try:
            with open(dest_path, 'wb') as f:
                f.write(file_data)
        except Exception as e:
            self._json_response({'error': f'Write failed: {e}'}, 500)
            return

        # Update .env with the custom/ relative path
        env_path = f'custom/{safe_name}'
        updates = {info['env_key']: env_path}
        save_env(updates)

        # Auto-apply config so branding takes effect immediately
        apply_config()

        self._json_response({
            'status': 'uploaded',
            'file': safe_name,
            'env_key': info['env_key'],
            'env_value': env_path,
            'applied': True
        })

    def _handle_upload_deploy(self, body):
        """Handle deploy script upload for self-update."""
        if len(body) < 1000:
            self._json_response({'error': 'File too small — likely not a valid deploy script'}, 400)
            return
        try:
            with open('/opt/seafile-deploy.sh', 'wb') as f:
                f.write(body)
            os.chmod('/opt/seafile-deploy.sh', 0o755)
            self._json_response({'status': 'uploaded', 'size': len(body)})
        except Exception as e:
            self._json_response({'error': f'Write failed: {e}'}, 500)

    def _parse_multipart(self, body, content_type):
        """Parse multipart/form-data. Returns (file_bytes, filename, form_fields)."""
        if 'multipart/form-data' not in content_type:
            # Not multipart — treat entire body as the file
            return body, 'upload.bin', {}

        boundary = None
        for part in content_type.split(';'):
            part = part.strip()
            if part.startswith('boundary='):
                boundary = part[9:].strip('"')
                break
        if not boundary:
            return None, None, {}

        boundary_bytes = f'--{boundary}'.encode()
        parts = body.split(boundary_bytes)
        file_data = None
        filename = 'upload.bin'
        form_fields = {}

        for part in parts:
            if not part or part == b'--\r\n' or part == b'--':
                continue
            # Split headers from body
            if b'\r\n\r\n' in part:
                header_section, part_body = part.split(b'\r\n\r\n', 1)
            elif b'\n\n' in part:
                header_section, part_body = part.split(b'\n\n', 1)
            else:
                continue

            headers = header_section.decode('utf-8', errors='replace')
            # Strip trailing boundary markers from body
            if part_body.endswith(b'\r\n'):
                part_body = part_body[:-2]

            # Extract field name and filename
            name_match = re.search(r'name="([^"]+)"', headers)
            fname_match = re.search(r'filename="([^"]+)"', headers)

            if fname_match:
                filename = fname_match.group(1)
                file_data = part_body
            elif name_match:
                form_fields[name_match.group(1)] = part_body.decode('utf-8', errors='replace').strip()

        return file_data, filename, form_fields

    def _serve_html(self):
        try:
            with open(HTML_FILE, 'rb') as f:
                content = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', len(content))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(500, 'config-ui.html not found')

    def _json_response(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stdout.write(f'[CONFIG-UI] {fmt % args}\n')
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    print(f'[CONFIG-UI] Starting on port {PORT}')
    print(f'[CONFIG-UI] Serving {HTML_FILE}')
    print(f'[CONFIG-UI] Reading {ENV_FILE}')
    server = http.server.HTTPServer(('0.0.0.0', PORT), ConfigHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('[CONFIG-UI] Stopped.')
