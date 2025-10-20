#!/usr/bin/env bash

set -euo pipefail

### Logging setup
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$(pwd)/deploy_${TIMESTAMP}.log"   ### FIX: make log file absolute
TMP_DIR="/tmp/deploy_build_${TIMESTAMP}"
mkdir -p "$TMP_DIR"

log() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOGFILE"; }
info() { log "INFO" "$1"; }
warn() { log "WARN" "$1"; }
error() { log "ERROR" "$1"; }
fatal() { log "FATAL" "$1"; exit "${2:-1}"; }

trap 'error "Unexpected error on line $LINENO"; exit 99' ERR

info "Starting interactive parameter collection..."

read -rp "Git Repository URL (HTTPS). Example: https://github.com/owner/repo.git: " GIT_URL
read -rp "Personal Access Token (used for cloning) (input will be visible here; ensure it's correct): " PAT
read -rp "Branch name (optional) [main]: " BRANCH
BRANCH="${BRANCH:-main}"
read -rp "Remote SSH username (e.g., ubuntu, root): " SSH_USER
read -rp "Remote server IP or hostname: " SSH_HOST
read -rp "Path to SSH private key [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
read -rp "Application internal container port (e.g., 3000): " APP_PORT

APP_NAME="$(basename -s .git "$GIT_URL")"
IMAGE_NAME="${APP_NAME,,}"
REMOTE_BASE_DIR="~/deployments"
REMOTE_APP_DIR="${REMOTE_BASE_DIR}/${APP_NAME}"

info "Application name: $APP_NAME"

# Verify SSH connectivity
info "Checking SSH connectivity to ${SSH_USER}@${SSH_HOST}..."
if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${SSH_HOST}" "echo ok" &>/dev/null; then
  info "SSH connectivity ok."
else
  fatal "SSH connection failed. Check your IP, username, or SSH key."
fi

# Clone or update repo
info "Cloning or updating repo..."
CLONE_DIR="${TMP_DIR}/${APP_NAME}"

if [[ -d "$CLONE_DIR/.git" ]]; then
  cd "$CLONE_DIR"
  git pull origin "$BRANCH" || fatal "Git pull failed"
else
  info "Cloning ${GIT_URL}..."
  git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" "$CLONE_DIR" || fatal "Git clone failed"
  cd "$CLONE_DIR"
fi

# Ensure Dockerfile or docker-compose exists
if [[ ! -f "Dockerfile" && ! -f "docker-compose.yml" ]]; then
  fatal "No Dockerfile or docker-compose.yml found in repository."
fi
info "Found Dockerfile or docker-compose file."

# Remote environment setup
remote_exec() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "$@"
}

info "Ensuring remote base dir: ${REMOTE_BASE_DIR}"
remote_exec "mkdir -p ${REMOTE_BASE_DIR} && chown \$(whoami):\$(whoami) ${REMOTE_BASE_DIR} || true"

REMOTE_SETUP_SCRIPT=$(cat <<'EOF'
set -e
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx
sudo usermod -aG docker $USER || true
sudo systemctl enable docker nginx
sudo systemctl start docker nginx
docker --version
docker compose version || docker-compose --version
nginx -v
EOF
)

info "Running remote environment setup..."
remote_exec "bash -lc '$(printf "%s" "$REMOTE_SETUP_SCRIPT" | sed "s/'/'\\\\''/g")'" || warn "Remote setup had warnings; continuing"   ### FIX: removed output redirection

# File transfer
info "Transferring project files to remote host..."
remote_exec "mkdir -p ${REMOTE_APP_DIR} && chown \$(whoami):\$(whoami) ${REMOTE_APP_DIR}"
info "Using rsync to copy project files..."
rsync -az -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" --exclude '.git' ./ "${SSH_USER}@${SSH_HOST}:${REMOTE_APP_DIR}/"

# Remote deploy command
if [[ -f "docker-compose.yml" ]]; then
  DEPLOY_CMD="cd ${REMOTE_APP_DIR} && sudo docker compose pull --ignore-pull-failures || true && sudo docker compose down --remove-orphans || true && sudo docker compose up -d --build"   ### FIX: added sudo
else
  DEPLOY_CMD="cd ${REMOTE_APP_DIR} && sudo docker build -t ${IMAGE_NAME} . && sudo docker rm -f ${APP_NAME} || true && sudo docker run -d --name ${APP_NAME} -p 127.0.0.1:${APP_PORT}:${APP_PORT} ${IMAGE_NAME}"   ### FIX: added sudo
fi

info "Executing remote deployment..."
if remote_exec "$DEPLOY_CMD"; then
  info "Deployment succeeded."
else
  fatal "Deployment command failed 50" 50
fi

info "Script finished successfully"
