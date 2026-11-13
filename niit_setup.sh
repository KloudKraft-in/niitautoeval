#!/usr/bin/env bash
# =============================================================================
#  NIIT ASSESSMENT PLATFORM - ONE-RUN UBUNTU VM SETUP
#  Target: Ubuntu 20.04 / 22.04 / 24.04 (x86_64)
#  Usage : sudo bash niit_setup.sh
#  Does  : 1) installs dependencies  2) downloads the Drive file
#          3) extracts zip  4) chmod +x  5) dpkg -i  (+ fixes missing deps)
# =============================================================================
set -uo pipefail

# ---------------------------- CONFIG -----------------------------------------
DRIVE_FILE_ID="1zLWvKfLTUBnJtKXs6Lae--vKi3hXCz7_"
WORKSPACE="/opt/NIIT_Workspace"
PY_VERSION="3.11"
NODE_MAJOR="20"
# -----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/niit_setup.log"
WORKDIR="$(mktemp -d /tmp/niit_setup.XXXXXX)"   # fresh, empty dir for downloads
trap 'rm -rf "$WORKDIR"' EXIT

c_y="\e[33m"; c_g="\e[32m"; c_r="\e[31m"; c_c="\e[36m"; c_0="\e[0m"
step() { echo -e "\n${c_y}[STEP] $*...${c_0}"; }
ok()   { echo -e "${c_g}[OK] $*${c_0}"; }
warn() { echo -e "${c_r}[WARN] $*${c_0}"; }
hdr()  { echo -e "${c_c}========================================================\n  $*\n========================================================${c_0}"; }

if [[ $EUID -ne 0 ]]; then
  echo -e "${c_r}[ERROR] Run as root:  sudo bash $0${c_0}"; exit 1
fi
exec > >(tee -a "$LOG") 2>&1

hdr "STARTING NIIT UBUNTU VM AUTOMATED SETUP"
. /etc/os-release
echo "OS: $PRETTY_NAME   Arch: $(dpkg --print-architecture)"

# ---------------------------------------------------------------------------
step "1/9: Base packages"
apt-get update -y
apt-get install -y ca-certificates curl wget gnupg lsb-release software-properties-common \
  unzip zip build-essential git apt-transport-https libpq-dev libffi-dev libssl-dev
ok "Base packages + Git installed ($(git --version))"

# ---------------------------------------------------------------------------
step "2/9: Python ${PY_VERSION}"
if ! apt-cache show "python${PY_VERSION}" >/dev/null 2>&1; then
  add-apt-repository -y ppa:deadsnakes/ppa && apt-get update -y
fi
apt-get install -y "python${PY_VERSION}" "python${PY_VERSION}-venv" "python${PY_VERSION}-dev" python3-pip python3-venv
if ! "python${PY_VERSION}" --version >/dev/null 2>&1; then
  warn "python${PY_VERSION} unavailable, falling back to system python3"
  PY_BIN="python3"
else
  PY_BIN="python${PY_VERSION}"
fi
ok "Python ready: $($PY_BIN --version)"

# ---------------------------------------------------------------------------
step "3/9: OpenJDK 17 + JAVA_HOME"
apt-get install -y openjdk-17-jdk
JAVA_DIR="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
cat > /etc/profile.d/niit_java.sh <<EOF
export JAVA_HOME="$JAVA_DIR"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
grep -q '^JAVA_HOME=' /etc/environment || echo "JAVA_HOME=\"$JAVA_DIR\"" >> /etc/environment
ok "Java ready (JAVA_HOME=$JAVA_DIR)"

# ---------------------------------------------------------------------------
step "4/9: Node.js ${NODE_MAJOR} LTS"
if ! command -v node >/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d v)" != "$NODE_MAJOR" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
npm install -g yarn pnpm typescript ts-node mocha jest || warn "Some global npm packages failed"
ok "Node ready: $(node --version)"

# ---------------------------------------------------------------------------
step "5/9: Visual Studio Code"
if ! command -v code >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
  apt-get update -y
  apt-get install -y code || warn "VS Code install failed (headless VM? safe to ignore)"
fi
ok "VS Code step done"

# ---------------------------------------------------------------------------
step "6/9: AWS CLI v2"
if ! command -v aws >/dev/null; then
  ARCH="$(uname -m)"   # x86_64 or aarch64
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$WORKDIR/awscliv2.zip"
  mkdir -p "$WORKDIR/aws_extract"
  unzip -q "$WORKDIR/awscliv2.zip" -d "$WORKDIR/aws_extract"
  "$WORKDIR/aws_extract/aws/install" --update
fi
ok "AWS CLI: $(aws --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
step "7/9: Workspace + Python assessment packages (venv)"
mkdir -p "$WORKSPACE" "$WORKSPACE/.vscode"
if [[ ! -d "$WORKSPACE/venv" ]]; then
  "$PY_BIN" -m venv "$WORKSPACE/venv"
fi
"$WORKSPACE/venv/bin/pip" install --upgrade pip setuptools wheel

PY_PKGS=(
  numpy pandas scipy scikit-learn matplotlib seaborn
  pyspark delta-spark databricks-sdk
  boto3 requests urllib3 sqlalchemy pymysql psycopg2-binary
  snowflake-connector-python python-dotenv
  pytest pytest-cov black flake8 beautifulsoup4 lxml pytz
)
"$WORKSPACE/venv/bin/pip" install "${PY_PKGS[@]}" || warn "Some Python packages failed - check log"

cat > "$WORKSPACE/.vscode/settings.json" <<'EOF'
{
  "python.defaultInterpreterPath": "./venv/bin/python",
  "python.terminal.activateEnvironment": true,
  "python.analysis.extraPaths": ["./student_workspace"],
  "editor.formatOnSave": true
}
EOF
chmod -R a+rX "$WORKSPACE"
# Make the venv the default python for all users' shells
cat > /etc/profile.d/niit_venv.sh <<EOF
export PATH="$WORKSPACE/venv/bin:\$PATH"
EOF
ok "Workspace ready at $WORKSPACE"

# VS Code Python extension (only if code exists; run as the invoking user)
if command -v code >/dev/null; then
  RUN_USER="${SUDO_USER:-root}"
  sudo -u "$RUN_USER" code --install-extension ms-python.python --force >/dev/null 2>&1 \
    && ok "VS Code Python extension installed" || warn "VS Code extension skipped"
fi

# ---------------------------------------------------------------------------
step "8/9: Download NIIT package from Google Drive"
# gdown handles Drive's large-file confirmation page; install in a throwaway venv
python3 -m venv "$WORKDIR/gdown_venv"
"$WORKDIR/gdown_venv/bin/pip" install -q gdown

DL_DIR="$WORKDIR/download"; mkdir -p "$DL_DIR"
OUT="$DL_DIR/niit_download"

is_valid() {   # real download = >1MB and NOT an HTML error/confirm page
  [[ -s "$1" ]] || return 1
  [[ $(stat -c%s "$1") -gt 1000000 ]] || return 1
  head -c 2048 "$1" | grep -qiE '<html|<!doctype html' && return 1
  return 0
}

# Parse Drive's "can't scan for viruses" confirm form and re-submit it
drive_form_download() {
  local page="$WORKDIR/drive_page.html" cj="$WORKDIR/cj.txt" url
  curl -sSL -c "$cj" "https://drive.google.com/uc?export=download&id=${DRIVE_FILE_ID}" -o "$page" || return 1
  url="$(python3 -I - "$page" <<'PY'
import re, sys, html
t = open(sys.argv[1], errors="ignore").read()
m = re.search(r'<form[^>]*id="download-form"[^>]*action="([^"]+)"', t) or re.search(r'<form[^>]*action="([^"]+)"', t)
if not m: sys.exit(1)
action = html.unescape(m.group(1))
params = dict(re.findall(r'<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"', t))
q = "&".join(f"{k}={html.unescape(v)}" for k, v in params.items())
print(action + ("&" if "?" in action else "?") + q)
PY
)" || return 1
  curl -fsSL -b "$cj" "$url" -o "$OUT"
}

try_download() {
  local n=0
  while (( n < 3 )); do
    n=$((n+1)); echo "Download attempt $n/3"
    rm -f "$OUT"
    "$WORKDIR/gdown_venv/bin/gdown" --fuzzy "https://drive.google.com/file/d/${DRIVE_FILE_ID}/view" -O "$OUT" && is_valid "$OUT" && return 0
    rm -f "$OUT"
    curl -fsSL "https://drive.usercontent.google.com/download?id=${DRIVE_FILE_ID}&export=download&confirm=t" -o "$OUT" && is_valid "$OUT" && return 0
    rm -f "$OUT"
    drive_form_download && is_valid "$OUT" && return 0
    sleep 5
  done
  return 1
}

if [[ -n "${NIIT_LOCAL_FILE:-}" && -f "$NIIT_LOCAL_FILE" ]]; then
  cp "$NIIT_LOCAL_FILE" "$OUT"; ok "Using local file: $NIIT_LOCAL_FILE"
elif try_download; then
  ok "Downloaded: $(du -h "$OUT" | cut -f1)"
else
  # Fallback: look for a manually downloaded copy
  RUN_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
  FOUND="$(find "$RUN_HOME/Downloads" /tmp -maxdepth 1 -type f \( -iname 'NIIT*.zip' -o -iname 'NIIT*.deb' \) 2>/dev/null | head -1)"
  if [[ -n "$FOUND" ]]; then
    warn "Drive download blocked - using local copy: $FOUND"
    cp "$FOUND" "$OUT"
  else
    echo -e "${c_r}[ERROR] Google Drive refused the download (permission / quota / 'Anyone with the link' not set).${c_0}"
    echo "  Fix 1: Drive > Share > General access = 'Anyone with the link' (Viewer)."
    echo "  Fix 2: Download the file in a browser, then run:"
    echo "         sudo NIIT_LOCAL_FILE=\"/path/to/NIIT.zip\" bash $0"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
step "9/9: Extract, chmod +x, dpkg -i"
EXTRACT_DIR="$WORKDIR/extracted"; mkdir -p "$EXTRACT_DIR"
FILE_TYPE="$(file -b "$DL_DIR/niit_download" 2>/dev/null || true)"
if [[ "$FILE_TYPE" == *"Zip archive"* ]] || unzip -tq "$DL_DIR/niit_download" >/dev/null 2>&1; then
  unzip -q -o "$DL_DIR/niit_download" -d "$EXTRACT_DIR"
  ok "Zip extracted"
else
  cp "$DL_DIR/niit_download" "$EXTRACT_DIR/package.deb"   # Drive file was the .deb itself
fi

# Filename may contain spaces/parentheses, e.g. "NIIT-4.6.0-amd64 (4).deb"
mapfile -d '' DEBS < <(find "$EXTRACT_DIR" -type f -iname '*.deb' -print0)
if [[ ${#DEBS[@]} -eq 0 ]]; then
  echo -e "${c_r}[ERROR] No .deb file found after extraction.${c_0}"; exit 1
fi

for deb in "${DEBS[@]}"; do
  echo "Installing: $deb"
  chmod +x "$deb"
  if ! dpkg-deb --info "$deb" >/dev/null 2>&1; then
    echo -e "${c_r}[ERROR] $deb is not a valid .deb (bad download?). Aborting.${c_0}"; exit 1
  fi
  if ! dpkg -i "$deb"; then
    warn "dpkg reported missing dependencies - fixing with apt"
    apt-get install -f -y
    dpkg -i "$deb" || { echo -e "${c_r}[ERROR] Install failed for $deb${c_0}"; exit 1; }
  fi
done
ok "NIIT .deb installed"

# ---------------------------------------------------------------------------
hdr "ALL DONE - SETUP COMPLETE"
echo "  Python : $($PY_BIN --version 2>&1)"
echo "  Java   : $(java -version 2>&1 | head -1)"
echo "  Node   : $(node --version)"
echo "  Git    : $(git --version)"
echo "  AWS CLI: $(aws --version 2>&1 | head -1)"
echo "  VSCode : $(command -v code || echo 'not installed')"
echo "  Space  : $WORKSPACE"
echo "  Log    : $LOG"
echo -e "\nLog out/in (or reboot) once so JAVA_HOME and PATH apply to all shells."
