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
#
# The chown is guarded: only a fresh (root-owned) mount pays the recursive
# walk. Once the volume holds real repos, chown -R over many small git
# objects on every boot would quietly grow until it ate the healthcheck
# window — and that failure looks identical to the outage this fixes.
if [ "$(id -u)" = "0" ]; then
  if [ "$(stat -c %u /data/git)" != "$(id -u buzz)" ]; then
    chown -R buzz:buzz /data/git
  fi
  exec gosu buzz "/usr/local/bin/$bin" "$@"
fi

exec "/usr/local/bin/$bin" "$@"
