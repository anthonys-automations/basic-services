FROM alpine:latest

RUN apk update && apk add tinyproxy

# tinyproxy will create its pid file (needs root for that) then drop privileges, so no runas user needed for container.

CMD ["/usr/bin/tinyproxy", "-d"]
