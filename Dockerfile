FROM alpine:3.20 AS builder

RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    linux-headers \
    pkgconfig \
    ldns-dev \
    nftables-dev \
    libmnl-dev

WORKDIR /build

# 1. Сборка awg-proxy
RUN git clone --depth 1 https://github.com/timbrs/amneziawg-mikrotik-c.git awg && \
    make -C /build/awg

# 2. Сборка dnspbr из исходников
RUN git clone --depth 1 https://github.com/postmdk/dnspbr.git dnspbr
WORKDIR /build/dnspbr
RUN if [ -f CMakeLists.txt ]; then \
        cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"; \
    elif [ -f Makefile ]; then \
        make -j"$(nproc)"; \
    fi

# Финальный образ
FROM alpine:3.20

RUN apk add --no-cache \
    wireguard-tools-wg-quick \
    iproute2 \
    nftables \
    ldns \
    libstdc++ \
    libgcc \
    ca-certificates \
    tzdata

COPY --from=builder /build/builds/awg-proxy /usr/local/bin/awg-proxy
COPY --from=builder /build/dnspbr/bin/dnspbr /usr/local/bin/dnspbr
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/awg-proxy /usr/local/bin/dnspbr /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
