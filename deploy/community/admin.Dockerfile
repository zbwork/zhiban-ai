FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app
COPY apps/agent-bus-admin/package.json apps/agent-bus-admin/pnpm-lock.yaml ./
RUN NODE_USE_ENV_PROXY=1 pnpm install --frozen-lockfile
COPY apps/agent-bus-admin/ ./
RUN pnpm build
FROM nginx:1.27-alpine
COPY --from=build /app/dist/ /usr/share/nginx/html/
COPY deploy/community/admin.nginx.conf /etc/nginx/conf.d/default.conf
