FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json tsconfig.json ./
COPY src ./src

RUN npm ci
RUN npm run build

CMD ["node", "dist/launcher.js"]
