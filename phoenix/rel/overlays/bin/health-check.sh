#!/bin/sh
# Container health check: the unauthenticated /api/health endpoint
# (version + database probe). Fails when the endpoint is unreachable
# or returns a non-2xx status.
set -e
wget --quiet --tries=1 --timeout=5 --spider "http://127.0.0.1:${PORT:-80}/api/health"
