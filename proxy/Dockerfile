FROM alpine:latest

RUN apk add --no-cache socat bash curl jq iproute2 busybox-extras

# Copy scripts
COPY set-container-status.sh /set-container-status.sh
COPY start-proxy.sh /start-proxy.sh
RUN chmod +x /set-container-status.sh
RUN chmod +x /start-proxy.sh

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
