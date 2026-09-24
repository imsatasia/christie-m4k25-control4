# Throwaway test image: there is no Lua on the host, and this driver targets
# Lua 5.1 specifically (what Control4 controllers run), not whatever Lua a
# host package manager happens to ship. Build once, reuse for every test run:
#
#   docker build -t christie-lua .
#
# This used to be a heredoc duplicated across three markdown files; it's a
# real file now so CI and local dev share one definition.
FROM alpine:3.24
RUN apk add --no-cache lua5.1 lua5.1-socket
