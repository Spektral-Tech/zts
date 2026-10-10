# ZTS controller image, bash essentials: the readable reference plus the tools it drives.
# The main image (Dockerfile) is the Go core; this one is kept in parity for inspection.
# Run with: --privileged --pid=host --network host -v /var/run/docker.sock:/var/run/docker.sock -v zts:/etc/zts
#
# Alpine's dnsmasq is built without nftset support, which is the one feature
# the name-based resources depend on, so dnsmasq is compiled here with it.
FROM alpine:3.20 AS dnsmasq
ARG DNSMASQ_VERSION=2.91
RUN apk add --no-cache build-base linux-headers nftables-dev curl xz \
    && curl -fsSL "https://thekelleys.org.uk/dnsmasq/dnsmasq-${DNSMASQ_VERSION}.tar.xz" | tar -C /tmp -xJ \
    && cd "/tmp/dnsmasq-${DNSMASQ_VERSION}" \
    && make -j"$(nproc)" COPTS="-DHAVE_NFTSET" \
    && strip src/dnsmasq && install -D -m 0755 src/dnsmasq /usr/local/sbin/dnsmasq \
    && /usr/local/sbin/dnsmasq --version | grep -q ' nftset'

FROM alpine:3.20
RUN apk add --no-cache \
      bash curl jq yq-go iproute2 nftables iptables wireguard-tools util-linux-misc \
    && rm -rf /var/cache/apk/*
COPY --from=dnsmasq /usr/local/sbin/dnsmasq /usr/local/sbin/dnsmasq
COPY zts.sh /usr/local/bin/zts
RUN chmod +x /usr/local/bin/zts && mkdir -p /etc/zts /run/zts
ENV ZTS_HOST_ROOT=/proc/1/root
VOLUME ["/etc/zts"]
ENTRYPOINT ["/usr/local/bin/zts"]
CMD ["up"]
