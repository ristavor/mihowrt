FROM --platform=linux/arm64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    e2fsprogs \
    gzip \
    iproute2 \
    netcat-openbsd \
    openssh-client \
    procps \
    qemu-system-x86 \
    qemu-utils \
    socat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /router

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
