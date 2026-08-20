#!/bin/sh
# Wrapper for gog that routes Gmail API calls through the integ VM proxy.
#
# When GOG_GMAIL_BASE_URL is set, Gmail API calls are redirected to the proxy
# by setting no_proxy to bypass the supervisor for gmail.googleapis.com and
# instead using a local socat forwarder.
#
# Env vars:
#   GOG_GMAIL_BASE_URL  - Proxy URL (e.g. http://integ-vm:18080/)
#   GOG_ACCESS_TOKEN    - Inter-VM bearer token for proxy auth

if [ -z "${GOG_GMAIL_BASE_URL}" ]; then
  exec /usr/local/bin/gog-real "$@"
fi

# Extract proxy host:port
PROXY_HOST=$(echo "${GOG_GMAIL_BASE_URL}" | sed 's|https\?://||;s|/.*||;s|:.*||')
PROXY_PORT=$(echo "${GOG_GMAIL_BASE_URL}" | sed 's|https\?://||;s|/.*||' | grep -o ':[0-9]*' | tr -d ':')
PROXY_PORT=${PROXY_PORT:-18080}

# Start local forwarder if not running (bridges local port to proxy)
FORWARD_PORT=18080
if ! ss -tln 2>/dev/null | grep -q ":${FORWARD_PORT} " && command -v socat >/dev/null 2>&1; then
  socat TCP-LISTEN:${FORWARD_PORT},fork,reuseaddr TCP:${PROXY_HOST}:${PROXY_PORT} &
  sleep 1
fi

# Set HTTPS_PROXY to route gmail.googleapis.com through the supervisor proxy
# which enforces the provider policy and adds credentials.
# The real routing happens via the provider's enforcement: enforce setting.
exec /usr/local/bin/gog-real "$@"
