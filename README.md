```markdown
# HNG 13 Stage 1 – DevOps Task

This repository contains my solution for the **HNG 13 Stage 1 DevOps task**.  
The goal of the task was to automate deployment using a Bash script (`deploy.sh`) that sets up a Node.js application inside a Docker container on a remote Ubuntu server and makes it publicly accessible via Nginx.

---

## 🚀 Application Information

- **Repository:** [codedCoderr/hng13-stage1-devops](https://github.com/codedCoderr/hng13-stage1-devops)
- **App Name:** `hng13-stage1-devops`
- **Server IP:** `54.242.49.206`
- **Internal App Port:** `3000`
- **Response Message:**
```

Hello from deploy.sh automation test!

````

---

## 🧩 What `deploy.sh` Does

The automation script performs the following steps:

1. **Collects parameters interactively** (Git repo, branch, SSH credentials, app port, etc.)
2. **Clones or updates** the specified GitHub repository on a temporary build directory
3. **Installs dependencies** on the remote server:
 - Docker
 - Docker Compose
 - Nginx
4. **Transfers project files** securely using `rsync`
5. **Builds the Docker image** (`node:18-alpine` base image)
6. **Runs the container** and maps it to the configured internal port
7. **Configures Nginx** as a reverse proxy to forward traffic from port `80` → `3000`
8. **Starts Nginx** and verifies the app is reachable

---

## 🐳 Dockerfile

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]
````

---

## ⚙️ Nginx Reverse Proxy Configuration

The script automatically configures Nginx to forward HTTP traffic to the running Node.js container.

Below is the default `/etc/nginx/sites-available/default` configuration:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
```

This setup ensures that visiting the server’s IP (`http://54.242.49.206`) routes requests directly to the app running inside Docker.

---

## 🌍 Verification

Once deployed, you can visit:

👉 **[http://54.242.49.206](http://54.242.49.206)**

Expected browser or `curl` output:

```
Hello from deploy.sh automation test!
```

---

## 🧾 Deployment Logs (excerpt)

```
[2025-10-20 22:04:25] [INFO] Deployment succeeded.
[2025-10-20 22:04:25] [INFO] Script finished successfully
```

---

## ✅ Status

- [x] SSH access verified
- [x] Docker image built successfully
- [x] Container running
- [x] Nginx configured as reverse proxy
- [x] App accessible via public IP
- [x] Automation completed successfully

---

## 🧠 Architecture Overview

**Workflow:**

```
GitHub Repo  →  deploy.sh (local)  →  Remote Server (EC2)
                                     ├── Docker (Node App)
                                     └── Nginx (Reverse Proxy)
Browser → http://54.242.49.206 → Nginx → Docker Container → Node.js App
```

---

## 👩🏽‍💻 Author

**Busola Olowu (@codedCoderr)**
HNG 13 DevOps Track – Stage 1
📧 Contact:codedcoderrr@gmail.com

---

```

---
```
