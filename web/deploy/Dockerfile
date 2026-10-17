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
# on. The live defaults below make a plain vpsinfra build complete; future
# deployments may override them with build args. Nothing secret may be among
# them.
#
# The defaults ARE the live deployment, not placeholders.
#
# They were placeholders - empty vaults and shares, and VITE_MUSD defaulting
# to 0x118917a4..., the MUSD the vaults reject - and nothing in the registry
# entry or in vpsinfra's deploy script passes these as build args. So a deploy
# would have shipped a dapp with no contract addresses, which renders "No
# contract addresses are configured in this build", settling in the wrong
# token if they had been filled in by hand. Silently: the build succeeds and
# the page looks deliberate.
#
# Addresses are permanent once deployed, so carrying them here is not a
# duplicate of ADDRESSES.md that can drift into being wrong - it can only
# drift into being old, which check-bundle.mjs below turns into a failed
# build rather than a quiet one. Override any of them with --build-arg.
ARG VITE_REOWN_PROJECT_ID="47d6b12386de55042b12dfbc95f7b44f"
ARG VITE_RPC_URL="https://rpc.test.mezo.org"
ARG VITE_CHAIN_ID="31611"
ARG VITE_FEED_URL=""
ARG VITE_PUBLIC_URL="https://leekdefi.0xoucanproject.xyz"
ARG VITE_VAULT_GOLOGGLE="0x68A86E4503FCA82ac9eB229Be655E355A019bcC3"
ARG VITE_VAULT_AMEZON="0x87c6925798769012085b9a71FabA87c31F894f18"
ARG VITE_SHARE_GOLOGGLE="0x35e0c3df250a1ea46bde6eef2D6ad22C924FCB88"
ARG VITE_SHARE_AMEZON="0x239cC4EB08B92fdB486F00C93E2D47b38c0EBAd4"
# The MUSD BorrowerOperations can mint, which is the only one a user can
# obtain by borrowing. Mezo testnet has five contracts reporting MUSD with 18
# decimals; see ADDRESSES.md for which and why this is the one.
ARG VITE_MUSD="0xf9BBcCC0F1b68EA07c86de6F88C76b3d8E2dD0af"
# Both default per chain id in src/config.ts, so they are here only to be
# overridden if Mezo re-points its proxy or moves the faucet.
ARG VITE_BORROWER_OPERATIONS=""
ARG VITE_NATIVE_FAUCET_URL=""
# `npm run build` ends with scripts/check-bundle.mjs, which fails the build if
# the bundle is missing an address the app needs or carries one of the four
# MUSD impostors. That is deliberately part of the build rather than a step
# here, so a local build cannot skip what a deploy enforces.
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
