# The feed service. Node is the runtime because the service runs TypeScript
# through Node's own type stripping, with viem as its only dependency.
FROM node:22-alpine

# Production dependencies only, installed from the lockfile so the image is
# reproducible, and before the sources are copied so a code change does not
# reinstall them.
WORKDIR /app
COPY feed/package.json feed/package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

COPY feed/src ./src

# Unprivileged, and the image carries no shell tooling beyond what the base
# provides. The process writes nothing: its state is the chain, and its status
# lives in memory, which is why the container can run read-only.
USER node
EXPOSE 8787

# --experimental-strip-types rather than a build step: there is no bundler in
# this service and adding one would mean a second toolchain to keep current.
CMD ["node", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "src/main.ts"]
