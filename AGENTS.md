# AGENTS.md

## Cursor Cloud specific instructions

This is a **Bash-based deployment toolkit** (not a traditional application). There is no web server to start or database to run for development — the "application" is the build system that assembles template scripts.

### Key development commands

- **Build**: `bash scripts/build.sh` — regenerates `scripts/update.sh`, `scripts/setup.sh`, and `seafile-deploy.sh` from templates in `src/`
- **Build + verify**: `bash scripts/build.sh --verify` — builds and runs syntax checks, marker verification, and structural checks on all generated output
- **Syntax check all scripts**: `bash -n scripts/*.sh` and `bash -n src/*.sh`
- **Lint (ShellCheck)**: `shellcheck -S warning scripts/build.sh` or any source file. Note: `src/shared-lib.sh` and `src/deploy-footer.sh` are fragments (no shebang) — ShellCheck SC2148 errors on these are expected
- **Python syntax**: `python3 -m py_compile scripts/gitops/seafile-gitops-sync.py` and `python3 -m py_compile scripts/config-ui/seafile-config-ui.py`
- **Clean build**: `bash scripts/build.sh --clean`

### Workflow

Edit source files in `src/` and `scripts/`, never edit generated files (`scripts/setup.sh`, `scripts/update.sh`, `seafile-deploy.sh`). After edits, run `bash scripts/build.sh --verify` and commit both source and generated files.

### No automated test suite

Per the README Developer Guide, there is no automated test suite. Verification is done via `build.sh --verify`, `bash -n` syntax checks, and manual testing on a Debian 13 VM with Docker.

### File permissions

Scripts in the repo may not have execute permissions set. Use `bash scripts/build.sh` instead of `./scripts/build.sh`.
