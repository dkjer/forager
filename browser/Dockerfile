FROM mcr.microsoft.com/playwright:v1.52.0-noble

WORKDIR /app

RUN npm init -y && npm install playwright@1.52.0

COPY server.js /app/server.js

EXPOSE 5012

CMD ["node", "/app/server.js"]
