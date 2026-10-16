FROM golang:1.26.1-bookworm AS build
WORKDIR /src
COPY services/agent-bus/go.mod services/agent-bus/go.sum ./
RUN go mod download
COPY services/agent-bus/ ./
RUN mkdir /out && for name in bus admin worker audit-writer migrate bootstrap; do CGO_ENABLED=0 go build -trimpath -o /out/community-$name ./cmd/community-$name; done

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* && useradd -u 10001 -r community
COPY --from=build /out/ /usr/local/bin/
USER community
CMD ["community-bus", "-config", "/etc/community/service.yaml"]
