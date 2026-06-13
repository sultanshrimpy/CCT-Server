FROM node:20-alpine

WORKDIR /app

# Install dependencies first (layer cache friendly)
COPY package.json ./
RUN npm install --omit=dev

# Copy source
COPY index.js ./

CMD ["node", "index.js"]
