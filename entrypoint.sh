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

# Railway volumes mount root-owned, masking the image's buzz-owned /data/git.
# When started as root, reclaim ownership of the data dirs, then drop to the
# buzz user. Without a volume the dirs are already buzz-owned and this is a
# cheap no-op.
if [ "$(id -u)" = "0" ]; then
  chown -R buzz:buzz /data/git
  exec gosu buzz "/usr/local/bin/$bin" "$@"
fi

exec "/usr/local/bin/$bin" "$@"
