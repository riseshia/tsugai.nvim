#!/bin/sh
# Build step for plugin managers: installs the sidecar's runtime dependencies from the lockfile.
set -eu
cd "$(dirname "$0")/sidecar"
npm ci --omit=dev
