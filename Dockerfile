# ---- build stage ----
FROM node:20-bookworm-slim AS build
WORKDIR /app

# CI-friendly env
ENV HUSKY=0
ENV CI=true
# DO NOT set NODE_ENV=production here - we need devDependencies

# Use pnpm
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

# Ensure git is available for build and runtime scripts
RUN apt-get update && apt-get install -y --no-install-recommends git \
  && rm -rf /var/lib/apt/lists/*

# Accept (optional) build-time public URL for Remix/Vite
ARG VITE_PUBLIC_APP_URL
ENV VITE_PUBLIC_APP_URL=${VITE_PUBLIC_APP_URL}

# Install deps efficiently
COPY package.json pnpm-lock.yaml* ./
RUN pnpm fetch

# Copy source
COPY . .

# Install with dev deps (needed to build) but skip scripts (no husky)
RUN pnpm install --offline --frozen-lockfile --ignore-scripts

# Build the Remix app (SSR + client) with NODE_ENV=production
RUN NODE_ENV=production NODE_OPTIONS=--max-old-space-size=4096 pnpm run build

# ---- production dependencies stage ----
FROM build AS prod-deps
# Now set NODE_ENV and keep only production deps for runtime
ENV NODE_ENV=production
RUN pnpm prune --prod --ignore-scripts

# ---- production stage ----
FROM node:20-bookworm-slim AS bolt-ai-production
WORKDIR /app

ENV NODE_ENV=production
# Don't hardcode PORT - let Railway inject it dynamically
ENV HOST=0.0.0.0
ENV RUNNING_IN_DOCKER=true
ENV NODE_OPTIONS="--max-old-space-size=4096"

# Non-sensitive build arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables
ENV WRANGLER_SEND_METRICS=false \
    VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX}

# Note: API keys should be provided at runtime via Railway environment variables

# Install curl for healthchecks
RUN apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

# Copy built files and scripts from previous stages
COPY --from=prod-deps /app/build /app/build
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=prod-deps /app/package.json /app/package.json
COPY --from=prod-deps /app/bindings.sh /app/bindings.sh

# Pre-configure wrangler to disable metrics
RUN mkdir -p /root/.config/.wrangler && \
    echo '{"enabled":false}' > /root/.config/.wrangler/metrics.json

# Make bindings script executable
RUN chmod +x /app/bindings.sh

# Healthcheck - uses Railway's PORT variable
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:${PORT:-5173}/ || exit 1

# Start using dockerstart script with Wrangler
CMD ["pnpm", "run", "dockerstart"]

# ---- development stage ----
FROM build AS development

# Non-sensitive development arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables for development
ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

# Note: API keys should be provided at runtime

RUN mkdir -p /app/run
CMD ["pnpm", "run", "dev", "--host"]