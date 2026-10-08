# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# The Trinity headless image, hardened (slice 130). This is the only recipe for it: the image the
# project publishes and the image submitted to Iron Bank are this file built with different
# arguments. Iron Bank's pipeline supplies BASE_REGISTRY and takes the other four from
# hardening_manifest.yaml; the published build takes them from ci/headless/bases.env, which pins
# each base by digest. docs/regulated/headless-image.md explains both.
#
# Nothing here reaches the network. Every input that is not a UBI package arrives in the build
# context as a file named in hardening_manifest.yaml, checked against its digest before the build
# starts (`scripts/headless_image.sh stage` does that for a local or CI build). dnf is the one
# exception, and it reaches only the UBI repositories, which Iron Bank proxies.
#
#   scripts/headless_image.sh build trinity-headless:hardened
#   docker run --rm -p 4000:4000 -e TRINITY_MCP_SERVER_TOKEN=... -e TRINITY_WEB_AUTH=oidc \
#     -e TRINITY_WEB_AUTH_ISSUER=... -e TRINITY_WEB_AUTH_CLIENT_ID=... trinity-headless:hardened

ARG BASE_REGISTRY=registry1.dso.mil/ironbank
ARG BASE_IMAGE=redhat/ubi/ubi9-micro
ARG BASE_TAG=9.8
ARG BUILDER_IMAGE=redhat/ubi/ubi9
ARG BUILDER_TAG=9.8

# The runtime base, named once so the root filesystem stage below can start from its contents.
FROM ${BASE_REGISTRY}/${BASE_IMAGE}:${BASE_TAG} AS runtime-base

# The build packages, the one step that reaches a package repository (UBI's, which Iron Bank
# proxies). It is a stage of its own so that every later step can be shown to build with no network
# at all (docs/regulated/headless-image.md). Compilers stay in the build stages.
FROM ${BASE_REGISTRY}/${BUILDER_IMAGE}:${BUILDER_TAG} AS build-packages

RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
      gcc gcc-c++ make perl git ncurses-devel openssl-devel tar gzip unzip findutils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# The toolchain: OTP from source and Elixir.
FROM build-packages AS toolchain

COPY otp_src_28.5.0.7.tar.gz elixir-1.20.4-otp-28.zip hex-2.5.1-otp-28.ez rebar3-3.25.1-otp-28 /build/resources/

# --enable-fips compiles the crypto NIF's FIPS support, and --with-ssl links UBI's OpenSSL
# dynamically, which is where Red Hat's FIPS provider lives (docs/fips-leg.md). Applications with
# no place in a server are left out of the build.
WORKDIR /build/otp
RUN tar -xzf /build/resources/otp_src_28.5.0.7.tar.gz --strip-components=1 \
    && ./configure --prefix=/usr/local --enable-fips --with-ssl=/usr \
         --without-javac --without-jinterface --without-wx --without-odbc \
         --without-debugger --without-observer --without-et --without-megaco \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /build/otp/*

ENV PATH=/usr/local/elixir/bin:/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8 \
    MIX_HOME=/opt/mix \
    HEX_HOME=/opt/hex \
    HEX_OFFLINE=1

WORKDIR /usr/local/elixir
RUN unzip -q /build/resources/elixir-1.20.4-otp-28.zip \
    && mix archive.install /build/resources/hex-2.5.1-otp-28.ez --force \
    && mix local.rebar rebar3 /build/resources/rebar3-3.25.1-otp-28 --force

# The release. Native pieces arrive pre-staged: the precompiled NIFs in the cache their loaders
# read before they would download, the XLA archive by path, exqlite compiled from the C source in
# its Hex package, the asset tools where their Mix tasks look for them.
FROM toolchain AS release

COPY trinity-src.tar.gz trinity-hex-deps.tar.gz \
     esbuild-linux-x64-0.25.4.tgz tailwindcss-linux-x64-4.3.0 \
     xla_extension-0.10.0-x86_64-linux-gnu-cpu.tar.gz \
     libex_tokenizers-v0.5.1-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz \
     libmdex_native_nif-v0.2.8-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz \
     /build/resources/

ENV MIX_ENV=prod \
    EXQLITE_FORCE_BUILD=1 \
    RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/build/nif-cache \
    XLA_ARCHIVE_PATH=/build/resources/xla_extension-0.10.0-x86_64-linux-gnu-cpu.tar.gz \
    XLA_CACHE_DIR=/build/xla-cache

WORKDIR /build/trinity
RUN tar -xzf /build/resources/trinity-src.tar.gz \
    && tar -xzf /build/resources/trinity-hex-deps.tar.gz \
    && mkdir -p /build/nif-cache _build \
    && cp /build/resources/libex_tokenizers-v0.5.1-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz \
          /build/resources/libmdex_native_nif-v0.2.8-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz \
          /build/nif-cache/ \
    && tar -xzf /build/resources/esbuild-linux-x64-0.25.4.tgz -C /build package/bin/esbuild \
    && install -m 0755 /build/package/bin/esbuild _build/esbuild-linux-x64 \
    && install -m 0755 /build/resources/tailwindcss-linux-x64-4.3.0 _build/tailwind-linux-x64-4.3.0

# The release cookie is removed: a cookie baked into a published image is a credential everyone who
# pulls it holds. The image runs with distribution off (RELEASE_DISTRIBUTION=none below), and
# scripts/entrypoint.sh gives each container its own cookie, which the start script requires.
RUN mix deps.compile \
    && mix assets.deploy \
    && mix release headless --overwrite \
    && rm -f _build/prod/rel/headless/releases/COOKIE

# The runtime root filesystem: ubi9-micro plus the libraries the release links, installed with
# dnf --installroot so micro's rpm database stays true to what is on disk, and the runtime user.
# The shells' default umask becomes 077, the STIG's value (RHEL-09-412055 and RHEL-09-412070), with
# the SCAP Security Guide's own fix expressions, as Iron Bank's own ubi9 sets it; nothing the image
# runs reads those files, so this changes no behaviour of the release.
FROM ${BASE_REGISTRY}/${BUILDER_IMAGE}:${BUILDER_TAG} AS rootfs

COPY --from=runtime-base / /rootfs/

RUN dnf -y --installroot=/rootfs --releasever=9 --setopt=reposdir=/etc/yum.repos.d \
        --setopt=install_weak_deps=False --nodocs \
        install libstdc++ openssl-libs \
    && dnf -y --installroot=/rootfs --releasever=9 --setopt=reposdir=/etc/yum.repos.d \
        --setopt=install_weak_deps=False --nodocs \
        upgrade \
    && dnf --installroot=/rootfs clean all \
    && rm -rf /rootfs/var/cache/dnf /rootfs/var/lib/dnf /rootfs/var/log/dnf* /rootfs/var/log/hawkey.log \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && groupadd --prefix /rootfs --gid 10001 trinity \
    && useradd --prefix /rootfs --uid 10001 --gid 10001 --no-log-init \
         --home-dir /data --no-create-home --shell /sbin/nologin trinity \
    && install -d -o 10001 -g 10001 -m 0700 /rootfs/data \
    && sed -i -E 's/^([^#]*\bumask)[[:space:]]+[[:digit:]]+/\1 077/g' /rootfs/etc/bashrc \
    && if grep -qsE '^[^#]*umask' /rootfs/etc/profile /rootfs/etc/profile.d/*.sh; then \
         sed -i -E 's/^(\s*umask\s*)[0-7]+/\1077/g' /rootfs/etc/profile; \
       else \
         printf 'umask 077\n' >> /rootfs/etc/profile; \
       fi

FROM ${BASE_REGISTRY}/${BASE_IMAGE}:${BASE_TAG}

COPY --from=rootfs /rootfs/ /
COPY --from=release --chown=0:0 /build/trinity/_build/prod/rel/headless /opt/trinity
COPY --chown=0:0 scripts/entrypoint.sh /usr/local/bin/trinity-entrypoint

# Distribution is off: the image serves MCP and the web pages on PORT and nothing else. The data
# directory is /data (XDG_DATA_HOME), the only path the runtime user can write. The secrets
# directory is /data/secrets (TRINITY_SECRETS_DIR, slice 135), beside the data directory on the
# same volume and never inside it: the receipt keys, the envelope key, the generated token. Point
# it at a systemd credential or a Kubernetes Secret mount instead (docs/packaging.md).
# Slice 136: 0.0.0.0 is not the loopback, so the node refuses to boot until TRINITY_WEB_AUTH says
# how the web pages authenticate (docs/mcp-server.md).
ENV LANG=C.UTF-8 \
    TRINITY_MODE=headless \
    TRINITY_BIND=0.0.0.0 \
    PORT=4000 \
    XDG_DATA_HOME=/data \
    TRINITY_SECRETS_DIR=/data/secrets \
    HOME=/data \
    RELEASE_DISTRIBUTION=none \
    RELEASE_TMP=/tmp

WORKDIR /opt/trinity
USER 10001:10001
VOLUME ["/data"]
EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/trinity-entrypoint"]
CMD ["/opt/trinity/bin/headless", "start"]
