# ---- build stage ----
FROM node:20-bookworm-slim AS build
WORKDIR /app

ENV HUSKY=0
ENV CI=true
# Don't set NODE_ENV=production here yet - we need devDependencies for the build
# ENV NODE_ENV=production  # REMOVED

RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

RUN apt-get update && apt-get install -y --no-install-recommends git \
  && rm -rf /var/lib/apt/lists/*

ARG VITE_PUBLIC_APP_URL
ENV VITE_PUBLIC_APP_URL=${VITE_PUBLIC_APP_URL}

COPY package.json pnpm-lock.yaml* ./
RUN pnpm fetch

COPY . .

# Install with dev dependencies (needed for build tools)
RUN pnpm install --offline --frozen-lockfile --ignore-scripts

# Build with NODE_ENV=production
RUN NODE_ENV=production NODE_OPTIONS=--max-old-space-size=4096 pnpm run build

# ---- production dependencies stage ----
FROM build AS prod-deps
# Now set NODE_ENV and prune
ENV NODE_ENV=production
RUN pnpm prune --prod --ignore-scripts

# ---- production stage ----
FROM node:20-bookworm-slim AS bolt-ai-production
WORKDIR /app

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV RUNNING_IN_DOCKER=true
ENV NODE_OPTIONS="--max-old-space-size=4096"

ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    WRANGLER_SEND_METRICS=false

RUN apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*

COPY --from=prod-deps /app/build /app/build
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=prod-deps /app/package.json /app/package.json
COPY --from=prod-deps /app/bindings.sh /app/bindings.sh

RUN mkdir -p /root/.config/.wrangler && \
    echo '{"enabled":false}' > /root/.config/.wrangler/metrics.json

RUN chmod +x /app/bindings.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:${PORT:-5173}/ || exit 1

CMD ["pnpm", "run", "dockerstart"]

# ---- development stage ----
FROM build AS development

ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

RUN mkdir -p /app/run
CMD ["pnpm", "run", "dev", "--host"]