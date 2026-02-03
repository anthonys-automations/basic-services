FROM alpine:latest

RUN apk update && apk add postfix

# postfix will bind to port 25 (needs root for that) then drop privileges, so no runas user needed for container.

CMD ["/usr/sbin/postfix", "-c", "/etc/postfix", "start-fg"]
