FROM --platform=$BUILDPLATFORM node:24-alpine AS frontend
WORKDIR /frontend-build
COPY web/ ./web/
RUN cd web && corepack enable && pnpm install --frozen-lockfile && pnpm build

FROM --platform=$BUILDPLATFORM golang:1.26.2-alpine AS backend
WORKDIR /backend-build
RUN apk add --no-cache git ca-certificates
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
COPY --from=frontend /frontend-build/web/dist ./server/router/frontend/dist
ARG TARGETOS TARGETARCH VERSION=dev COMMIT=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build \
      -trimpath \
      -ldflags="-s -w -X github.com/usememos/memos/internal/version.Version=${VERSION} -X github.com/usememos/memos/internal/version.Commit=${COMMIT} -extldflags '-static'" \
      -tags netgo,osusergo \
      -o memos \
      ./cmd/memos

FROM alpine:3.21 AS monolithic
RUN apk add --no-cache tzdata ca-certificates su-exec curl && \
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc && \
    addgroup -g 10001 -S nonroot && \
    adduser -u 10001 -S -G nonroot -h /var/opt/memos nonroot && \
    mkdir -p /var/opt/memos /usr/local/memos && \
    chown -R nonroot:nonroot /var/opt/memos
COPY --from=backend /backend-build/memos /usr/local/memos/memos
COPY scripts/entrypoint.sh /usr/local/memos/entrypoint.sh
RUN chmod 755 /usr/local/memos/entrypoint.sh
USER root
WORKDIR /var/opt/memos
VOLUME /var/opt/memos
ENV TZ="UTC" MEMOS_PORT="5230"
EXPOSE 5230
ENTRYPOINT ["/usr/local/memos/entrypoint.sh", "/usr/local/memos/memos"]
