# syntax=docker/dockerfile:1

# SPDX-License-Identifier: MIT

ARG TREALLA_VERSION=v3.12.6

FROM debian:bookworm-slim AS trealla-build
ARG TREALLA_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git make gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch "$TREALLA_VERSION" \
      https://github.com/trealla-prolog/trealla.git trealla \
    && make -C trealla -j"$(nproc)" NOSSL=1 NOFFI=1 NOTTY=1

FROM debian:bookworm-slim
ARG TREALLA_VERSION
LABEL org.opencontainers.image.title="Trealla Web Prolog node" \
      org.opencontainers.image.source="https://github.com/torbjornlager/trealla-port" \
      org.opencontainers.image.version="$TREALLA_VERSION" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 webprolog \
    && useradd --uid 10001 --gid webprolog --create-home webprolog \
    && mkdir -p /app /opt/trealla/library /state \
    && chown webprolog:webprolog /state

COPY --from=trealla-build /src/trealla/tpl /opt/trealla/tpl
COPY --from=trealla-build /src/trealla/library/ /opt/trealla/library/
COPY --from=trealla-build /src/trealla/LICENSE /src/trealla/ATTRIBUTION /usr/share/doc/trealla/
COPY --chown=webprolog:webprolog . /app/

WORKDIR /app

ENV TPL_LIBRARY_PATH=/opt/trealla/library \
    TPL=/opt/trealla/tpl \
    HOME=/home/webprolog \
    WP_PORT=3060

RUN chmod 0755 /app/Deployment/entrypoint.sh \
    && WP_ADMIN_TOKEN=build-check-token-000000000000 \
       /opt/trealla/tpl -g \
       "(catch((use_module('/app/Deployment/start_node.pl'),deployment_start:check_config),E,(writeq(E),nl,fail))->halt(0);halt(1))"

USER webprolog
EXPOSE 3060

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD /opt/trealla/tpl -g "use_module(library(http)),catch((http_open('http://127.0.0.1:3060/healthz',S,[timeout(3)]),close(S)),_,halt(1)),halt"

ENTRYPOINT ["/app/Deployment/entrypoint.sh"]
