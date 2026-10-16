# Build public upstream source: legacy MinIO image/binary endpoints are unavailable.
FROM golang:1.26.1-bookworm AS build
RUN GOBIN=/out CGO_ENABLED=0 go install github.com/minio/minio@RELEASE.2025-10-15T17-29-55Z
RUN GOBIN=/out CGO_ENABLED=0 go install github.com/minio/mc@RELEASE.2025-08-13T08-35-41Z
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
ENTRYPOINT []
