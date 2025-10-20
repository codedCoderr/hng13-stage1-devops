#!/usr/bin/env bash
# deploy.sh
# Author: ChatGPT (generated)
# Purpose: Automate setup, deployment, and configuration of a Dockerized app on a remote Linux server.
# POSIX-friendly but uses bash features. Make executable with: chmod +x deploy.sh

set -o errexit
set -o pipefail
set -o nounset

### Exit codes (examples)
# 0  - success
# 10 - input validation error
# 20 - git/clone error
# 30 - ssh/connection error
# 40 - remote setup error
# 50 - deploy/runtime error
# 60 - nginx/config error
# 70 - cleanup failure

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"
APP_NAME=""
TMP_DIR="/tmp/deploy_build_${TIMESTAMP}"

# Basic logging
log() {
  local level="$1"; shift
  local msg="$*"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOGFILE"
}

fatal() {
  log "FATAL" "$*"
  exit "${2:-1}"
}

info() { log "INFO" "$*"; }
warn() { log "WARN" "$*"; }
debug() { log "DEBUG" "$*"; }

# Trap for unexpected errors
cleanup_on_exit() {
  local rc=$?
  if [ $rc -ne 0 ]; then
    log "ERROR" "Script exited with code $rc"
  else
    log "INFO" "Script finished successfully"
  fi
  # optional tmp cleanup
  if [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR" || true
    log "DEBUG" "Removed tmp dir $TMP_DIR"
  fi
}
trap cleanup_on_exit EXIT

usage() {
  cat <<EOF
Usage: $0 [--cleanup] [-y]

Run interactive deployment to a remote server over SSH.

Options:
  --cleanup    Remove deployed resources from remote host (nginx config, docker containers/images, project dir)
  -y           Non-interactive yes (accept prompts default)
  -h,--help    Show this help
EOF
  exit 0
}

# parse flags
CLEANUP=0
AUTOYES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=1; shift ;;
    -y) AUTOYES=1; AUTOYES=1; shift ;; # no-op guard (typo safe)
    -h|--help) usage ;;
    *) shift ;;
  esac
done

# Interactive prompts with validation
prompt() {
  local var_name="$1"; local prompt_text="$2"; local default="${3:-}"
  local input
  if [ "${AUTOYES:-0}" -eq 1 ] && [ -n "$default" ]; then
    input="$default"
    info "Auto-selected default for $var_name: $input"
  else
    printf "%s" "$prompt_text"
    if [ -n "$default" ]; then
      printf " [%s]" "$default"
    fi
    printf ": "
    read -r input
    if [ -z "$input" ] && [ -n "$default" ]; then
      input="$default"
    fi
  fi
  eval "$var_name=\"\$input\""
}

# Validate a simple ip format (not bulletproof)
is_ip() {
  case "$1" in
    ([0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
    (*) return 1 ;;
  esac
}

# Prompt for required info
info "Starting interactive parameter collection..."
prompt REPO_URL "Git Repository URL (HTTPS). Example: https://github.com/owner/repo.git"
prompt PAT "Personal Access Token (used for cloning) (input will be visible here; ensure it's correct)"
prompt BRANCH "Branch name (optional)" "main"
prompt SSH_USER "Remote SSH username (e.g., ubuntu, root)"
prompt SSH_HOST "Remote server IP or hostname"
prompt SSH_KEY "Path to SSH private key" "~/.ssh/id_rsa"
prompt APP_PORT "Application internal container port (e.g., 3000)"

# Expand ~ in key path
SSH_KEY="${SSH_KEY/#\~/$HOME}"

# Basic validations
[ -n "$REPO_URL" ] || fatal "Git repo URL required" 10
[ -n "$PAT" ] || fatal "PAT required" 10
[ -n "$SSH_USER" ] || fatal "SSH username required" 10
[ -n "$SSH_HOST" ] || fatal "SSH host required" 10
[ -n "$SSH_KEY" ] || fatal "SSH key path required" 10
[ -f "$SSH_KEY" ] || fatal "SSH key file not found at $SSH_KEY" 10
[ -n "$APP_PORT" ] || fatal "App port required" 10

# derive APP_NAME from repo url
APP_NAME="$(basename -s .git "$REPO_URL" | tr '[:upper:]' '[:lower:]')"
if [ -z "$APP_NAME" ]; then
  APP_NAME="app_${TIMESTAMP}"
fi
info "Application name: $APP_NAME"

SSH_TARGET="${SSH_USER}@${SSH_HOST}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# helper to run commands over ssh with error detection
remote_exec() {
  local cmd="$1"
  info "SSH -> $SSH_TARGET : $cmd"
  ssh $SSH_OPTS "$SSH_TARGET" "bash -lc '$cmd'"
}

# Connectivity check (ssh dry-run)
info "Checking SSH connectivity to $SSH_TARGET..."
if ! ssh $SSH_OPTS -o BatchMode=yes "$SSH_TARGET" "echo SSH_OK" >/dev/null 2>&1; then
  fatal "Unable to connect to $SSH_TARGET via SSH. Check network, firewall, and key." 30
fi
info "SSH connectivity ok."

# If cleanup mode: proceed to remote cleanup and exit
if [ "${CLEANUP:-0}" -eq 1 ]; then
  info "Cleanup mode requested. Will attempt to remove deployed resources."
  remote_exec "set -e
    echo 'Stopping containers related to ${APP_NAME}...'
    docker ps -a --filter 'name=${APP_NAME}' -q | xargs -r docker rm -f || true
    echo 'Removing images (if any)...'
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '${APP_NAME}' -E || true
    # remove nginx config
    sudo rm -f /etc/nginx/sites-enabled/${APP_NAME} /etc/nginx/sites-available/${APP_NAME} || true
    sudo nginx -t || true
    sudo systemctl reload nginx || true
    # remove project dir
    rm -rf ~/deployments/${APP_NAME} || true
    echo 'Cleanup done.'"
  info "Remote cleanup requested completed."
  exit 0
fi

# Prepare local clone/pull
mkdir -p "$TMP_DIR"
cd "$TMP_DIR" || fatal "Could not cd to $TMP_DIR" 20

# Build an auth'd clone URL: insert PAT into HTTPS url
# Support both https://github.com/owner/repo.git and https://github.com/owner/repo
AUTHED_REPO_URL="$REPO_URL"
if echo "$REPO_URL" | grep -qE '^https?://'; then
  # strip https:// and recompose
  stripped="$(echo "$REPO_URL" | sed -E 's#https?://##')"
  AUTHED_REPO_URL="https://${PAT}@${stripped}"
fi

info "Cloning or updating repo..."
if [ -d "$APP_NAME" ]; then
  info "Repo already exists. Attempting git pull..."
  cd "$APP_NAME"
  if ! git fetch --all --prune >>"$LOGFILE" 2>&1; then
    fatal "git fetch failed" 20
  fi
  if ! git checkout "$BRANCH" >>"$LOGFILE" 2>&1; then
    warn "Branch $BRANCH not found; trying to checkout origin/$BRANCH"
    git checkout -b "$BRANCH" "origin/$BRANCH" >>"$LOGFILE" 2>&1 || warn "Could not checkout branch $BRANCH — continuing on current branch"
  fi
  git pull origin "$BRANCH" >>"$LOGFILE" 2>&1 || warn "git pull failed"
else
  info "Cloning $AUTHED_REPO_URL..."
  if ! git clone --branch "$BRANCH" --single-branch "$AUTHED_REPO_URL" "$APP_NAME" >>"$LOGFILE" 2>&1; then
    warn "Clone with branch failed; attempting clone without branch..."
    git clone "$AUTHED_REPO_URL" "$APP_NAME" >>"$LOGFILE" 2>&1 || fatal "git clone failed" 20
    cd "$APP_NAME" || fatal "Cannot cd to cloned dir" 20
    git checkout "$BRANCH" >>"$LOGFILE" 2>&1 || warn "Could not checkout branch $BRANCH"
  fi
  cd "$APP_NAME" || fatal "Cannot cd to cloned dir" 20
fi

# Check for dockerfile or docker-compose.yml
if [ -f Dockerfile ] || [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  info "Found Dockerfile or docker-compose file."
else
  fatal "No Dockerfile or docker-compose.yml found in repo root. Cannot proceed." 20
fi

# Prepare remote directory
REMOTE_BASE="~/deployments"
REMOTE_APP_DIR="${REMOTE_BASE}/${APP_NAME}"

info "Ensuring remote base dir: $REMOTE_BASE"
remote_exec "mkdir -p ${REMOTE_BASE} && chown \$(whoami):\$(whoami) ${REMOTE_BASE} || true"

# Remote environment setup script (idempotent)
read -r -d '' REMOTE_SETUP_SCRIPT <<'EOS' || true
set -e
# Determine package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG=apt
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
elif command -v dnf >/dev/null 2>&1; then
  PKG=dnf
else
  echo "Unsupported package manager"
  exit 1
fi

echo "Using package manager: $PKG"

if [ "$PKG" = "apt" ]; then
  sudo apt-get update -y
  # install prerequisites
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  # Docker repo setup
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  else
    echo "Docker already installed"
  fi
  # docker-compose-plugin is modern
  if ! docker compose version >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin || true
  fi
  sudo apt-get install -y nginx || true
else
  # yum/dnf flow (RHEL/CentOS/Alma)
  sudo ${PKG} -y update || true
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo bash
  else
    echo "Docker already installed"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || true
    sudo chmod +x /usr/local/bin/docker-compose || true
  fi
  sudo ${PKG} -y install nginx || true
fi

# Add user to docker group if docker exists and group exists
if command -v docker >/dev/null 2>&1; then
  DOCKER_GID=$(getent group docker | cut -d: -f3 || true)
  if ! groups $(whoami) | grep -qw docker; then
    sudo usermod -aG docker $(whoami) || true
    echo "User added to docker group; may need relogin"
  fi
  docker --version || true
  docker compose version || true
fi

# Ensure services
sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true

echo "REMOTE_SETUP_COMPLETE"
EOS

# Run remote setup
info "Running remote environment setup..."
remote_exec "bash -lc '$(printf "%s" "$REMOTE_SETUP_SCRIPT" | sed "s/'/'\\\\''/g")'" >/dev/null 2>&1 || warn "Remote setup had warnings; continuing"

# Transfer files using rsync over SSH for efficiency
info "Transferring project files to remote host..."
# ensure remote app dir exists
remote_exec "mkdir -p ${REMOTE_APP_DIR} && chown \$(whoami):\$(whoami) ${REMOTE_APP_DIR}"
# Use rsync if available
if command -v rsync >/dev/null 2>&1; then
  info "Using rsync to copy project files..."
  # exclude .git and node_modules and .env by default
  rsync -avz --delete --exclude='.git' --exclude='node_modules' --exclude='.env' -e "ssh $SSH_OPTS" "./" "${SSH_USER}@${SSH_HOST}:${REMOTE_APP_DIR}" >>"$LOGFILE" 2>&1 || fatal "rsync failed" 30
else
  info "rsync not found locally; using scp fallback..."
  # tar and send over ssh
  tar -czf - . | ssh $SSH_OPTS "$SSH_TARGET" "tar -xzf - -C ${REMOTE_APP_DIR}" >>"$LOGFILE" 2>&1 || fatal "scp/tar transfer failed" 30
fi

# Deploy: if docker-compose present prefer compose
DEPLOY_CMD=""
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  info "docker-compose file detected. Will use docker compose."
  DEPLOY_CMD="cd ${REMOTE_APP_DIR} && docker compose pull --ignore-pull-failures || true && docker compose down --remove-orphans || true && docker compose up -d --build"
else
  # Dockerfile flow: build an image and run container
  info "Dockerfile detected. Will build image and run container."
  IMAGE_NAME="${APP_NAME}:latest"
  DEPLOY_CMD="cd ${REMOTE_APP_DIR} && docker build -t ${IMAGE_NAME} . && docker rm -f ${APP_NAME} || true && docker run -d --name ${APP_NAME} -p 127.0.0.1:${APP_PORT}:${APP_PORT} ${IMAGE_NAME}"
fi

info "Executing remote deployment..."
remote_exec "$DEPLOY_CMD" >>"$LOGFILE" 2>&1 || fatal "Deployment command failed" 50

# Validate container health and running status
info "Validating container status..."
validate_cmd="docker ps --filter 'name=${APP_NAME}' --format '{{.Names}} {{.Status}}' || true"
remote_exec "$validate_cmd" >>"$LOGFILE" 2>&1 || warn "Could not list containers"

# Create Nginx site config on remote
NGINX_CONF_PATH="/etc/nginx/sites-available/${APP_NAME}"
NGINX_SYM="/etc/nginx/sites-enabled/${APP_NAME}"
read -r -d '' NGINX_CONF <<EOF || true
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

info "Uploading Nginx configuration and enabling site..."
# Use bash heredoc to write file remotely
remote_exec "echo \"${NGINX_CONF//\"/\\\"}\" | sudo tee ${NGINX_CONF_PATH} > /dev/null && sudo ln -sf ${NGINX_CONF_PATH} ${NGINX_SYM} && sudo nginx -t && sudo systemctl reload nginx" >>"$LOGFILE" 2>&1 || fatal "Nginx config failed or test failed" 60

# Validation: test local and remote endpoint (remote curl from the server to localhost:APP_PORT)
info "Testing endpoint from remote host (server->localhost)..."
remote_exec "set -e; sleep 2; if command -v curl >/dev/null 2>&1; then curl -I --max-time 5 http://127.0.0.1:${APP_PORT} || true; else wget -S -O - --timeout=5 http://127.0.0.1:${APP_PORT} || true; fi" >>"$LOGFILE" 2>&1 || warn "Remote internal curl test returned non-200 or timed out (check app logs)"

info "Testing endpoint through Nginx (server->localhost:80)..."
remote_exec "if command -v curl >/dev/null 2>&1; then curl -I --max-time 5 http://127.0.0.1/ || true; else wget -S -O - --timeout=5 http://127.0.0.1/ || true; fi" >>"$LOGFILE" 2>&1 || warn "Remote Nginx test failed or timed out"

# Optional local validation from control machine
info "Testing from control machine to remote host (public HTTP)..."
if command -v curl >/dev/null 2>&1; then
  if curl -I --connect-timeout 5 "http://${SSH_HOST}/" >/dev/null 2>&1; then
    info "Public HTTP check succeeded"
  else
    warn "Public HTTP check failed (port 80 may be blocked or firewall not open). Try curl http://${SSH_HOST} to inspect."
  fi
fi

info "Deployment finished. Logs written to $LOGFILE"
echo
echo "SUMMARY:"
echo "  App name: $APP_NAME"
echo "  Remote dir: $REMOTE_APP_DIR"
echo "  App internal port: $APP_PORT"
echo "  Nginx site: /etc/nginx/sites-available/${APP_NAME}"
echo "  Logfile: $LOGFILE"
echo
exit 0
