# Minimal production-ready Dockerfile (generic)
FROM node:18-alpine

WORKDIR /app

# install deps
COPY package*.json ./
RUN npm ci --production

# copy source
COPY . .

# build if you have a build step (optional)
# RUN npm run build

# expose container internal port (change if your app uses another port)
EXPOSE 3000

# start command (adjust as needed)
CMD ["node", "server.js"]
