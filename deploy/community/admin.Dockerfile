FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app
COPY apps/agent-bus-admin/package.json apps/agent-bus-admin/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY apps/agent-bus-admin/ ./
RUN pnpm exec vite build --config vite.community.config.ts
FROM nginx:1.27-alpine
COPY --from=build /app/dist-community/ /usr/share/nginx/html/
COPY deploy/community/admin.nginx.conf /etc/nginx/conf.d/default.conf
