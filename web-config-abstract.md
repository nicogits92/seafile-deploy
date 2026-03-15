# Web Configuration Interface — Design Abstract

## Overview

A lightweight web-based configuration editor for Seafile deployments that
eliminates the need to SSH into the host for routine .env changes. This is
a companion to (not a replacement for) the `seafile config` CLI — it serves
users who prefer a visual interface over a terminal.

## Problem Statement

Today, every .env change requires SSH access to the host machine. This is
fine for technical users but creates a barrier for less experienced
administrators who may be managing Seafile for a small team or family. The
web interface would let them change settings (enable SMTP, adjust quotas,
toggle features) from a browser without learning command-line tools.

## Architecture

### Container Design

A single lightweight container (`seafile-config-ui`) running a Python
Flask/FastAPI application. Estimated resources: ~30MB image, ~20MB RAM at
runtime.

```yaml
# Addition to docker-compose.yml
seafile-config-ui:
  image: ${CONFIG_UI_IMAGE:-seafile-config-ui:latest}
  container_name: seafile-config-ui
  restart: unless-stopped
  profiles:
    - config-ui
  volumes:
    - /opt/seafile/.env:/app/.env
    - /var/run/docker.sock:/var/run/docker.sock:ro
  environment:
    - CONFIG_UI_PORT=${CONFIG_UI_PORT:-9443}
    - ADMIN_EMAIL=${INIT_SEAFILE_ADMIN_EMAIL}
  ports:
    - "${CONFIG_UI_PORT:-9443}:9443"
  networks:
    - seafile-net
```

The container would be gated behind a Docker Compose profile (`config-ui`)
so it only runs when explicitly enabled via `CONFIG_UI_ENABLED=true`.

### Security Model

- **Authentication**: HTTP Basic Auth using the Seafile admin email and a
  dedicated `CONFIG_UI_PASSWORD` from .env (not the Seafile admin password
  — different credential for defense in depth)
- **HTTPS**: Served behind the existing Caddy reverse proxy at `/admin/config`
  so it inherits whatever SSL the deployment already has
- **Read/write scope**: Can only read and write `/opt/seafile/.env`. Cannot
  execute arbitrary commands. Cannot access Seafile user data.
- **Docker socket**: Read-only access, used only to display container status
  (like `seafile status`). Not used for exec or write operations.
- **No outbound network**: The container doesn't need internet access

### How Changes Propagate

```
Browser → config-ui writes .env → inotifywait (env-sync) detects change
  → cp to NFS share (DR backup)
  → git commit to config history (versioning)
  → POST to Portainer webhook (if PORTAINER_MANAGED=true)
```

The web UI only writes to `.env`. All downstream propagation is handled by
the existing env-sync infrastructure. This means:

- Config history captures every change with timestamps
- Network share backup stays current
- Portainer resyncs automatically
- No new propagation code needed in the web UI itself

For changes that require config regeneration (e.g., enabling SMTP, changing
office suite), the web UI would show a banner: "Changes saved. Run
`seafile fix` to apply." Or, with Docker socket access, it could trigger
`docker exec seafile bash -c 'seafile fix'` automatically — but this
requires careful consideration of the security implications.

## User Experience

### Navigation

The UI would be organized into the same sections as `seafile config`:

```
┌──────────────────────────────────────────────────────┐
│  Seafile Configuration                    [Status ●] │
├──────────────────────────────────────────────────────┤
│                                                      │
│  Server     Storage     Database     Proxy           │
│  Office     Email       LDAP         Features        │
│                                                      │
│  ─────────────────────────────────────────────────── │
│                                                      │
│  Server Configuration                                │
│                                                      │
│  Hostname     [ seafile.example.com    ]             │
│  Protocol     ( ) HTTP  (●) HTTPS                    │
│  Time Zone    [ America/New_York       ]             │
│  Admin Email  [ admin@example.com      ]             │
│                                                      │
│  ─────────────────────────────────────────────────── │
│                                                      │
│            [ Save Changes ]    [ Discard ]            │
│                                                      │
│  Last saved: 2026-03-10 14:32                        │
│  Config history: 47 versions                         │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **Section-based, not raw file editing.** Users see categorized fields
   with labels and descriptions, not raw KEY=VALUE pairs.

2. **Validation before save.** Required fields are highlighted. Invalid
   values (e.g., non-numeric port) are caught before writing.

3. **Diff before apply.** After clicking Save, show what changed:
   "SMTP_ENABLED: false → true, SMTP_HOST: (blank) → smtp.gmail.com"
   with a Confirm/Cancel step.

4. **Status awareness.** A status indicator shows container health (green/
   yellow/red) similar to `seafile status`. Helps the user see if their
   change had the desired effect.

5. **Secret masking.** Passwords and tokens are shown as `••••••••` with a
   reveal toggle. Never sent in plaintext in GET responses.

6. **Read-only fields.** DO NOT CHANGE variables are visible but greyed out
   with an explanation of why they can't be modified.

7. **Config history integration.** A "History" tab shows recent changes
   (pulled from the git repo) with the ability to view diffs and roll back.

### Sections

Each section maps to a group of .env variables:

| Section | Variables | Notes |
|---------|-----------|-------|
| Server | HOSTNAME, PROTOCOL, TIME_ZONE, ADMIN_EMAIL | Core identity |
| Storage | STORAGE_TYPE, NFS_*, SMB_*, etc. | Shows relevant fields based on type |
| Database | DB_INTERNAL, DB_HOST, DB_PASSWORD, etc. | Toggle between internal/external |
| Proxy | PROXY_TYPE, CADDY_PORT, TRAEFIK_* | Type-specific sub-fields |
| Office | OFFICE_SUITE, COLLABORA_*, ONLYOFFICE_* | Suite-specific sub-fields |
| Email | SMTP_ENABLED, SMTP_HOST, SMTP_PORT, etc. | Expandable when enabled |
| LDAP | LDAP_ENABLED, LDAP_URL, LDAP_BASE_DN, etc. | Expandable when enabled |
| Features | GC, Backup, ClamAV, WebDAV, 2FA, Guests | Toggles with sub-fields |

### Changes That Require Restart

Some .env changes take effect on next `docker compose up` (image tags,
port mappings). Others need config-fixes to regenerate config files. The
UI should categorize changes and tell the user what action is needed:

- **Immediate**: Changes to variables read directly by containers via
  environment (SEAFILE_SERVER_HOSTNAME, SEAFILE_SERVER_PROTOCOL)
- **Needs config-fixes**: Changes to variables that affect generated config
  files (SMTP_*, LDAP_*, OFFICE_SUITE, GC_*)
- **Needs stack restart**: Changes to docker-compose variables (image tags,
  port mappings, volume paths)

## Technical Implementation

### Stack

- **Backend**: Python 3 with FastAPI (lightweight, async, auto-generates
  OpenAPI docs). Single file, ~400 lines.
- **Frontend**: Vanilla HTML + CSS + minimal JavaScript. No build step, no
  npm, no framework. Served as static files by FastAPI. ~300 lines.
- **No database**: Reads/writes .env directly. Config history comes from
  the existing git repo.
- **Container base**: `python:3.12-alpine` (~50MB) with `pip install
  fastapi uvicorn` (~15MB additional).

### Deployment

Gated behind a profile so it doesn't run unless enabled:

```bash
# Enable
seafile config  # → Features → toggle "Web config UI"
# This sets CONFIG_UI_ENABLED=true and runs seafile update

# Or manually:
echo "CONFIG_UI_ENABLED=true" >> /opt/seafile/.env
seafile update
```

### .env Variables

```
CONFIG_UI_ENABLED=false
CONFIG_UI_PORT=9443
CONFIG_UI_PASSWORD=              # Auto-generated during setup if enabled
```

### Building the Image

The Dockerfile would be minimal:

```dockerfile
FROM python:3.12-alpine
RUN pip install --no-cache-dir fastapi uvicorn
COPY app/ /app/
WORKDIR /app
EXPOSE 9443
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9443"]
```

The image could be pre-built and published to Docker Hub alongside the
other Seafile images, or built locally during setup. Pre-built is
preferred for simplicity.

## Integration Points

### With seafile CLI

The web UI and CLI would coexist without conflict. Both write to the same
.env file, and env-sync handles propagation regardless of the source. The
only coordination needed is file locking (flock) to prevent simultaneous
writes — env-sync already handles this gracefully.

### With config history

The web UI reads from the git history for its History tab. It calls
`git log` and `git diff` against the existing repo at
`/opt/seafile/.config-history/`. No separate version tracking needed.

### With Portainer

If PORTAINER_MANAGED=true, the web UI can display a note:
"Changes are automatically synced to Portainer." No special integration
needed — env-sync handles the webhook.

### With GitOps

If GITOPS_INTEGRATION=true, the web UI should either:
- Be read-only (changes should come from the repo), with a link to the
  repo's web UI, OR
- Allow edits with a warning: "This deployment is git-managed. Local
  changes will be pushed to the repo." (if bidirectional sync is enabled)

## Estimated Effort

| Component | Lines | Time |
|-----------|-------|------|
| Backend (FastAPI + .env read/write) | ~400 | 1-2 days |
| Frontend (HTML/CSS/JS) | ~300 | 1-2 days |
| Dockerfile + compose integration | ~30 | 1 hour |
| CLI integration (enable/disable) | ~20 | 1 hour |
| .env variables + shared-lib | ~10 | 30 min |
| Testing all sections | — | 1 day |
| **Total** | ~760 | 4-6 days |

## Open Questions

1. **Should the web UI be able to trigger config-fixes automatically?**
   This requires Docker socket write access (to exec into containers),
   which is a security escalation. Alternative: show "Run seafile fix"
   instructions after save.

2. **Should it support multi-user access?** The current design uses a
   single shared password. For team use, individual accounts with audit
   logging would be valuable but significantly more complex.

3. **Should it be a separate repo/image?** Keeping it in this repo adds
   maintenance burden. A separate repo with its own release cycle might
   be cleaner, with this project just referencing the image tag.

4. **Mobile responsive?** If the UI will be accessed from phones (e.g.,
   quick check while away from desk), the frontend needs responsive
   design from the start.
