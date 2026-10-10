# ZTS controller image, Go main lane: one static binary plus nft (the ruleset
# interface) and iptables (to open Docker's DOCKER-USER chain).
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /zts ./cmd/zts

FROM alpine:3.20
RUN apk add --no-cache nftables iptables && rm -rf /var/cache/apk/*
COPY --from=build /zts /usr/local/bin/zts
RUN mkdir -p /etc/zts
ENV ZTS_HOST_ROOT=/proc/1/root
VOLUME ["/etc/zts"]
ENTRYPOINT ["/usr/local/bin/zts"]
CMD ["up"]
