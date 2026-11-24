# OpenTofu + Unclick toolbox.
# Contains: tofu, unclick, jq, bash, curl, git, and the AWS + AzureRM providers
# pre-installed in the plugin cache (so `tofu init` / `unclick` need no provider download).
#
# Build (amd64 + arm64):
#   docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/YOUR_ORG/tofu-unclick:1 --push .

FROM ghcr.io/opentofu/opentofu:1.13.10-minimal AS tofu

FROM alpine:3.22
ARG TARGETARCH
RUN apk add --no-cache bash ca-certificates curl git jq
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# Unclick, checksum-verified
ARG UNCLICK_VERSION=1.0.1
RUN set -e; arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) sha=3215bf4a649c193e6f75c17e1857572b0ab5c793a2daa6bc468b02ff90f90a95 ;; \
      arm64) sha=873342ae9f0a03c5b51b6117a65eee1c54236d0e64a24546ffa5fdb6658de291 ;; \
      *) echo "unsupported arch $arch" >&2; exit 1 ;; \
    esac; \
    wget -qO /tmp/u.tgz "https://github.com/Perruer/unclick/releases/download/v${UNCLICK_VERSION}/unclick_${UNCLICK_VERSION}_linux_${arch}.tar.gz"; \
    echo "$sha  /tmp/u.tgz" | sha256sum -c -; \
    tar -xzf /tmp/u.tgz -C /usr/local/bin unclick; \
    rm /tmp/u.tgz

# Pre-install providers into the shared plugin cache (writable, so other providers can be added at runtime)
ENV TF_PLUGIN_CACHE_DIR=/opt/plugin-cache
RUN set -e; mkdir -p "$TF_PLUGIN_CACHE_DIR" /tmp/p; cd /tmp/p; \
    printf '%s\n' \
      'terraform {' \
      '  required_providers {' \
      '    aws     = { source = "hashicorp/aws", version = "~> 6.0" }' \
      '    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }' \
      '  }' \
      '}' > main.tf; \
    tofu init -input=false -no-color; \
    cd /; rm -rf /tmp/p; \
    chmod -R a+rwX "$TF_PLUGIN_CACHE_DIR"

# Defaults that work for any user ID; override with -e / environment:
ENV HOME=/tmp \
    UNCLICK_CACHE_DIR=/tmp/unclick \
    TF_IN_AUTOMATION=1 \
    CHECKPOINT_DISABLE=1

# A writable working directory
RUN mkdir -p /workspace && chmod 777 /workspace
WORKDIR /workspace
