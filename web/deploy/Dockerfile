# Build the static bundle, then serve it from an image with no build tools and
# no shell utilities beyond what the base carries. Two stages so npm, the
# toolchain and node_modules - the overwhelming majority of the bytes - never
# reach the thing exposed to the internet.

FROM node:22-alpine AS build
WORKDIR /app
# package.json and the lockfile first, so a source-only change reuses the
# dependency layer instead of re-resolving 300 packages.
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
# Every VITE_* value is baked in here, at build time, and is public from then
# on. vpsinfra passes them as build args; nothing secret may be among them.
ARG VITE_REOWN_PROJECT_ID=""
ARG VITE_RPC_URL="https://rpc.test.mezo.org"
ARG VITE_FEED_URL=""
ARG VITE_PUBLIC_URL="https://leekdefi.0xoucanproject.xyz"
ARG VITE_VAULT_GOLOGGLE=""
ARG VITE_VAULT_AMEZON=""
ARG VITE_SHARE_GOLOGGLE=""
ARG VITE_SHARE_AMEZON=""
ARG VITE_MUSD="0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503"
RUN npm run build

FROM caddy:2.11.4-alpine
# The image ships caddy with cap_net_bind_service so it can bind 80. This
# container binds 8080 and is reached through the host's Caddy, so that
# capability grants nothing and is removed: a public-facing binary should not
# keep a privilege nothing in this deployment uses. libcap is installed only
# to run setcap and is deleted in the same layer, so the final image has no
# setcap binary either.
RUN apk add --no-cache libcap \
    && setcap -r /usr/bin/caddy \
    && apk del libcap
COPY --from=build --chown=10001:10001 /app/dist /srv/
USER 10001:10001
EXPOSE 8080
# `caddy file-server` writes nothing: no cache directory, no log file, no
# config file to persist. That is what makes READ_ONLY=true work with no
# tmpfs mount, which the registry entry relies on.
CMD ["caddy", "file-server", "--root", "/srv", "--listen", ":8080"]
