FROM --platform=linux/amd64 rust:1.90-bookworm AS builder

RUN apt-get update && apt-get install -y protobuf-compiler pkg-config libssl-dev git make cmake g++ && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ARG OPENSHELL_REF=main
RUN git clone --depth 1 --branch "${OPENSHELL_REF}" \
    https://github.com/NVIDIA/OpenShell.git .

WORKDIR /build/examples/governance-interceptor
RUN cargo build --release --target-dir /out

FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /out/release/governance-interceptor /usr/local/bin/governance-interceptor
ENTRYPOINT ["governance-interceptor"]
