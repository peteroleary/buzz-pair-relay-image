#!/bin/sh
# Dispatch to the binary named by BUZZ_BINARY (default: buzz-pair-relay).
# The image ships all three relay binaries, so one repo can back multiple
# Railway services — which binary a service runs is an env-var decision.
set -eu

bin="${BUZZ_BINARY:-buzz-pair-relay}"
case "$bin" in
  buzz-relay|buzz-pair-relay|buzz-admin) ;;
  *) echo "buzz-entrypoint: unknown BUZZ_BINARY '$bin'" >&2; exit 64 ;;
esac

exec "/usr/local/bin/$bin" "$@"
