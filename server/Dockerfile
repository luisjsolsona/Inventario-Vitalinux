FROM node:20-alpine

WORKDIR /app

COPY package.json .
RUN npm install --production

COPY src/ ./src/
COPY public/ ./public/
COPY agent/ ./agent/

RUN mkdir -p /app/data

EXPOSE 3900

CMD ["node", "src/index.js"]
