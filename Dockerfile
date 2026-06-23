FROM neosmemo/memos:0.29.1

USER root
RUN apk add --no-cache curl && \
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc

COPY scripts/entrypoint.sh /usr/local/memos/entrypoint.sh
RUN chmod 755 /usr/local/memos/entrypoint.sh

USER root
ENTRYPOINT ["/usr/local/memos/entrypoint.sh", "/usr/local/memos/memos"]
