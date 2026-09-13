#!/usr/bin/env bash
# tests/pi-web-front.sh: our config/pi-web-front/proxy.conf replaces the image's
# /etc/nginx/conf.d/include/proxy.conf. It must stay the stock file except for the Host and
# Origin lines, or an NPM upgrade would silently lose whatever upstream changed there.
#
#   tests/pi-web-front.sh [--image IMAGE]      (default: the Image= pinned in the unit)
#
# Reads the stock file from the image with a throwaway `podman run --rm` (no ports, no
# volumes, no network), normalises whitespace and comments, and diffs. scripts/upgrade.sh
# runs it against the new image before switching when the front is enabled; the
# pi-web-front CI workflow runs it against the pinned image.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
image=''
while (($#)); do
  case $1 in
    --image) image=${2:?--image needs a reference}; shift ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
[[ -n $image ]] || image=$(sed -n 's/^Image=//p' "$REPO/quadlet/npm-app.container" | tail -n1)
norm() { sed -e 's/#.*$//' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$'; }
stock=$(podman run --rm --network none --entrypoint cat "$image" /etc/nginx/conf.d/include/proxy.conf) \
  || { echo "pi-web-front: cannot read proxy.conf from $image" >&2; exit 2; }
# shellcheck disable=SC2016 # nginx variables, matched literally
ours=$(norm <"$REPO/config/pi-web-front/proxy.conf" \
  | sed -e 's/^proxy_set_header Host \$woow_upstream_host;$/proxy_set_header Host $host;/' \
  | grep -vxF 'proxy_set_header Origin $woow_upstream_origin;')
if diff -u <(norm <<<"$stock") <(printf '%s\n' "$ours"); then
  echo "pi-web-front: $image proxy.conf matches ours except the Host/Origin lines"
else
  echo "pi-web-front: FAIL: $image changed its proxy.conf (diff above: - image, + ours with the rewrite undone)." >&2
  echo "Port the change into config/pi-web-front/proxy.conf before upgrading." >&2
  exit 1
fi
