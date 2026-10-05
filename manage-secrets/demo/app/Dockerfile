FROM alpine:3.20

RUN apk add --no-cache curl jq postgresql16-client
COPY app.sh /app.sh

ENTRYPOINT ["sh", "/app.sh"]
