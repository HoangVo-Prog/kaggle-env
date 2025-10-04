#!/usr/bin/env bash
# setup_python_kaggle.sh
# Switch Python used by CLI in Kaggle by creating a conda env and rewiring python symlinks
# Usage:
#   bash setup_python_kaggle.sh            # defaults to 3.8
#   bash setup_python_kaggle.sh 3.10
#   PY_VER=3.9 ENV_NAME=newCondaEnvironment bash setup_python_kaggle.sh
set -euo pipefail

# ---------- Config ----------
PY_VER="${1:-${PY_VER:-3.8}}"
ENV_NAME="${ENV_NAME:-newCondaEnvironment}"
CONDA_ROOT="/opt/conda"
ENV_PATH="$CONDA_ROOT/envs/$ENV_NAME"
BACKUP_FILE="/tmp/python_symlinks_backup.txt"
ROLLBACK_SCRIPT="/tmp/rollback_python.sh"
ESSENTIAL_PKGS=(jupyter jupyter_core jupyter_client ipykernel nbconvert papermill numpy pandas)

# sudo helper
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi

log() { printf "%s\n" "$*" ; }
header() { printf "\n============================================================\n%s\n============================================================\n\n" "$*"; }
run() { bash -lc "$*"; }

# ---------- 1) Document current environment ----------
header "PYTHON ENVIRONMENT SWITCHER FOR KAGGLE V3"
log "[1] DOCUMENTING CURRENT ENVIRONMENT"
python -V || true
which python || true
python - <<'PY'
import sys
print("Python full:", sys.version)
print("Executable:", sys.executable)
print("Prefix    :", sys.prefix)
PY

log "Conda env list:"
run "conda env list || true"

log "Current Python symlinks:"
run "ls -la $CONDA_ROOT/bin/python* || true"

ORIG_PY3=$(readlink -f "$CONDA_ROOT/bin/python3" || true)
ORIG_PY=$(readlink -f "$CONDA_ROOT/bin/python" || true)
ORIG_JUPYTER=$(command -v jupyter || true)

# Backup symlink info
{
  ls -la "$CONDA_ROOT/bin/python"* 2>/dev/null || true
  echo "Original python3: $ORIG_PY3"
  echo "Original python : $ORIG_PY"
  echo "Original jupyter: $ORIG_JUPYTER"
} > "$BACKUP_FILE"
log "Backup saved to $BACKUP_FILE"

# Test script
cat > /tmp/test_version.py <<'PY'
import sys
print(f"Python {sys.version}")
print(f"Executable: {sys.executable}")
print(f"Path prefix: {sys.prefix}")
PY

log "Test current environment with python:"
python /tmp/test_version.py || true

# ---------- 2) Create new conda environment ----------
header "[2] CREATING NEW CONDA ENVIRONMENT WITH PYTHON=$PY_VER"
run "conda create -n \"$ENV_NAME\" python=\"$PY_VER\" -c conda-forge -y"

# ---------- 3) Install essential packages ----------
header "[3] INSTALLING ESSENTIAL PACKAGES INTO $ENV_NAME"
run "conda install -n \"$ENV_NAME\" ${ESSENTIAL_PKGS[*]} -c conda-forge -y"

# ---------- 4) Verify new environment ----------
header "[4] VERIFYING NEW ENVIRONMENT"
if [[ -d "$ENV_PATH" ]]; then
  log "✓ Environment directory exists: $ENV_PATH"
else
  log "✗ Environment directory not found: $ENV_PATH"
  exit 1
fi

CANDIDATES=("$ENV_PATH/bin/python" "$ENV_PATH/bin/python3" "$ENV_PATH/bin/python${PY_VER}")
NEW_PY=""
for p in "${CANDIDATES[@]}"; do
  if [[ -x "$p" ]]; then
    log "✓ Found Python: $p"
    "$p" --version
    [[ -z "$NEW_PY" ]] && NEW_PY="$p"
  else
    log "Not found: $p"
  fi
done

NEW_JUP="$ENV_PATH/bin/jupyter"
if [[ -x "$NEW_JUP" ]]; then
  log "✓ Jupyter found in new env: $NEW_JUP"
else
  log "✗ Jupyter not found in new env, something went wrong"
fi

if [[ -z "$NEW_PY" ]]; then
  header "ERROR: Could not find python in new environment"
  exit 1
fi

# ---------- 5) Rewire symlinks ----------
header "[5] REWIRING PYTHON SYMLINKS TO $NEW_PY"
# Remove only python symlinks
for link in "$CONDA_ROOT/bin/python" "$CONDA_ROOT/bin/python3"; do
  if [[ -L "$link" ]]; then
    $SUDO rm -f "$link"
    log "Removed symlink: $link"
  fi
done

# Create new symlinks
$SUDO ln -sf "$NEW_PY" "$CONDA_ROOT/bin/python"
$SUDO ln -sf "$NEW_PY" "$CONDA_ROOT/bin/python3"
log "Created symlinks:"
run "ls -la $CONDA_ROOT/bin/python $CONDA_ROOT/bin/python3"

# Update jupyter symlink if present in new env
if [[ -x "$NEW_JUP" ]]; then
  $SUDO rm -f "$CONDA_ROOT/bin/jupyter" 2>/dev/null || true
  $SUDO ln -sf "$NEW_JUP" "$CONDA_ROOT/bin/jupyter"
  log "Updated jupyter symlink -> $NEW_JUP"
fi

# ---------- 6) Verify and test ----------
header "[6] VERIFYING SYMLINK CHANGES"
log "Targets:"
for link in "$CONDA_ROOT/bin/python" "$CONDA_ROOT/bin/python3" "$CONDA_ROOT/bin/jupyter"; do
  if [[ -e "$link" ]]; then
    tgt=$(readlink -f "$link" || true)
    log "  $link -> $tgt"
  fi
done

log "Versions after switch:"
python --version || true
python3 --version || true
jupyter --version || true
python /tmp/test_version.py || true

# Basic imports
header "[7] TESTING PACKAGE AVAILABILITY"
python - <<'PY' || true
pkgs = ["numpy","pandas","matplotlib","sklearn","jupyter_core","ipykernel"]
for p in pkgs:
    try:
        mod = __import__(p)
        v = getattr(mod, "__version__", "unknown")
        print(f"  ✓ {p}: {v}")
    except Exception as e:
        print(f"  ✗ {p}: {e}")
PY

# ---------- 7) Create rollback script ----------
header "[8] CREATING ROLLBACK SCRIPT"
cat > "$ROLLBACK_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONDA_ROOT="/opt/conda"
BACKUP_FILE="/tmp/python_symlinks_backup.txt"
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi

echo "Rolling back Python symlinks using $BACKUP_FILE"
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "Backup file not found. Trying best effort rollback to base python"
fi

# Remove modified symlinks
for link in "$CONDA_ROOT/bin/python" "$CONDA_ROOT/bin/python3" "$CONDA_ROOT/bin/jupyter"; do
  [[ -L "$link" ]] && $SUDO rm -f "$link" && echo "Removed: $link"
done

# Try to parse originals from backup
ORIG_PY3=$(grep -E '^Original python3:' "$BACKUP_FILE" 2>/dev/null | awk '{print $3}') || true
ORIG_PY=$(grep -E '^Original python :' "$BACKUP_FILE" 2>/dev/null | awk '{print $3}') || true
ORIG_JUPYTER=$(grep -E '^Original jupyter:' "$BACKUP_FILE" 2>/dev/null | awk '{print $3}') || true

fallback_py="$CONDA_ROOT/bin/python3.11"
[[ -x "$ORIG_PY3" ]] && fallback_py="$ORIG_PY3"
[[ -x "$ORIG_PY" ]] && fallback_py="$ORIG_PY"

if [[ -x "$fallback_py" ]]; then
  $SUDO ln -sf "$fallback_py" "$CONDA_ROOT/bin/python"
  $SUDO ln -sf "$fallback_py" "$CONDA_ROOT/bin/python3"
  echo "Restored python symlinks to $fallback_py"
else
  echo "Could not locate original python. Leaving python symlinks absent."
fi

if [[ -x "$ORIG_JUPYTER" ]]; then
  $SUDO ln -sf "$ORIG_JUPYTER" "$CONDA_ROOT/bin/jupyter"
  echo "Restored jupyter to $ORIG_JUPYTER"
fi

echo "Current versions:"
python --version || true
python3 --version || true
jupyter --version || true
echo "Rollback complete"
SH
chmod +x "$ROLLBACK_SCRIPT"
log "Rollback script created at $ROLLBACK_SCRIPT"
log "To rollback, run: bash $ROLLBACK_SCRIPT"

# ---------- 8) Summary ----------
header "ENVIRONMENT SWITCH COMPLETE"
log "SUMMARY:"
log "  ✓ Backup saved: $BACKUP_FILE"
log "  ✓ Conda env: $ENV_NAME with Python $PY_VER"
log "  ✓ Essential packages installed"
log "  ✓ Symlinks updated"
log ""
log "CURRENT STATE:"
log "  Python: $(python --version 2>&1)"
log "  Location: $(which python 2>/dev/null || true)"
log "  Jupyter: $(jupyter --version 2>/dev/null | head -n1 || echo 'unknown')"
log ""
log "NOTES:"
log "  1) Jupyter kernel in this notebook still runs the original Python."
log "  2) System calls and !python will use the new symlink."
log "  3) To rollback: bash $ROLLBACK_SCRIPT"
