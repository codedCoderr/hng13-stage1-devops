# deploy.sh — Automated Docker App Deployment Script

A single-file Bash deployment script that automates cloning a Git repo (using a PAT), preparing a remote Linux host (Docker, Docker Compose, Nginx), transferring files, deploying the containerized app, configuring Nginx as a reverse proxy, validating the deployment, and logging everything.

## Features

- Interactive prompts (repo URL, PAT, branch, SSH details, internal app port)
- Authenticated `git clone` using PAT (HTTPS)
- Supports `docker-compose.yml` (preferred) or `Dockerfile` single-image deployments
- Installs Docker, Docker Compose, and Nginx on the remote host (Debian/Ubuntu and basic yum/dnf support)
- Transfers project files via `rsync` (or tar+scp fallback)
- Configures Nginx site to proxy traffic to the container
- Validates deployment (container status, curl checks)
- Timestamped logfile `deploy_YYYYMMDD_HHMMSS.log`
- Trap and cleanup handlers
- Idempotent behavior: stops/removes old containers before redeploying
- `--cleanup` remote cleanup mode to remove deployed resources

## Requirements

- Local machine: `bash`, `git`, `rsync` (recommended), `ssh` client, `curl` (optional)
- Remote server: SSH access; supports apt (Debian/Ubuntu) or yum/dnf (RHEL/CentOS/Fedora)
- A Git repo accessible via HTTPS
- A Personal Access Token (PAT) with repo read access
- Ensure port 80 is open on the remote host if you want HTTP accessible externally

## Usage

1. Make script executable:

```bash
chmod +x deploy.sh
```
