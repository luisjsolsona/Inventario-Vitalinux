# Contexto de build: raíz del repo (ver docker-compose.yml)
FROM node:20-alpine

WORKDIR /app

COPY server/package.json .
RUN npm install --production

COPY server/src/ ./src/
COPY server/public/ ./public/
# Única copia del agente: agent/ en la raíz del repo
COPY agent/ ./agent/

RUN mkdir -p /app/data

EXPOSE 3900

CMD ["node", "src/index.js"]
