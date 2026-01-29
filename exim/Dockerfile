FROM alpine:latest

RUN apk update && apk add exim

# exim will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

CMD ["/usr/sbin/exim", "-bdf", "-q30"]
