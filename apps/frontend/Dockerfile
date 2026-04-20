# syntax=docker/dockerfile:1.6
#
# openvelox-dashboard — Next.js 15 (App Router + PPR) image for GKE.
#
# Three-stage build:
#   deps   — reproducible install from the committed lockfile
#   build  — `next build` with Next's `output: "standalone"` trace so
#            only the files the server actually imports end up in the
#            runtime layer (cuts the image from ~1.2 GB to ~180 MB)
#   runner — slim, non-root, read-only-fs-friendly
#
# The runtime image does NOT include npm or the full node_modules tree.
# Next's standalone output copies just the transitive closure it needs;
# static assets go under /app/public and /app/.next/static and are
# served directly by `node server.js`.

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund --prefer-offline

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Next's telemetry pings home on every build — not useful in CI, and it
# adds network egress + noise to the build logs.
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
# Bind explicitly to 0.0.0.0 so the container listens on the interface
# that the K8s Service/Gateway forwards to, and keep the port aligned
# with infra/k8s/apps/base/dashboard-deployment.yaml.
ENV HOSTNAME=0.0.0.0
ENV PORT=3000

# Run as the unprivileged node user (UID 1000) that's baked into the
# base image; no uid allocation drift between rebuilds.
RUN addgroup --system --gid 1001 nodejs \
 && adduser --system --uid 1001 nextjs

COPY --from=build --chown=nextjs:nodejs /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# `next build` with output: "standalone" emits server.js at the root of
# the standalone tree (which we copied to /app).
CMD ["node", "server.js"]
