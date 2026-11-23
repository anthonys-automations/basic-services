FROM docker.io/library/alpine:3.24.3

# Build-time provenance: the Git commit this image was built from, requested so a
# running container can be traced back to source for audit. Kept as an env var
# (not just an OCI label) so it is readable from inside the container, and
# declared after the package layers so a new commit does not invalidate the apk
# cache.
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

RUN apk update && apk add --no-cache transmission-daemon dante jq

# 2 MiB default thread stack via libdsocks' PT_GNU_STACK (see below).
RUN apk add --no-cache --virtual .stack python3 \
 && python3 -c 'import struct,sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); o=struct.unpack_from("<Q",b,32)[0]; e,n=struct.unpack_from("<HH",b,54); i=next(o+k*e for k in range(n) if struct.unpack_from("<I",b,o+k*e)[0]==0x6474e551); struct.pack_into("<Q",b,i+40,2<<20); open(p,"wb").write(b)' /usr/lib/libdsocks.so \
 && apk del .stack

USER 100:101