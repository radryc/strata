FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund --legacy-peer-deps
COPY tracing.js server.js ./
ENV NODE_OPTIONS=--require=/app/tracing.js
EXPOSE 8080
CMD ["node", "server.js"]
