# A relay in a container. Build it from the repository root:
#
#   docker build -f deploy/relay/Dockerfile -t tetrix-host-relay .
#   docker run --rm -p 8787:8787 tetrix-host-relay
#
# The relay speaks plain WebSocket on port 8787. Put TLS in front of it.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tetrix-host ./cmd/tetrix-host

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/tetrix-host /tetrix-host
EXPOSE 8787
ENTRYPOINT ["/tetrix-host", "relay", "serve", "--listen", ":8787"]
