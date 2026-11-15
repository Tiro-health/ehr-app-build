#!/usr/bin/env bash
# Packages a built app into a container image for tirohealth.app.
#
# Run it from the root of an app repository after `check` and `build` passed. The shared
# workflow (.github/workflows/build.yml) calls it, and a developer can run it the same way
# on a laptop to get an equivalent image. It needs Docker and no credentials.
#
#   scripts/package.sh [--image <repository>:<tag>] [--tar <file.tar.gz>]
#
#   --image  The reference to tag the image with. Default: <directory name>:local,
#            lowercased. The workflow passes <repository>:<commit or v* tag>.
#   --tar    Also write the image as a gzipped `docker save` tarball (what the `tiro-image`
#            artifact holds).
#
# The image is built for linux/amd64 from:
# - .output/server/index.mjs: a Node server (e.g. TanStack Start with Nitro) listening on $PORT.
# - dist/index.html: a static single-page app, served by nginx with unknown paths falling
#   back to index.html.
#
# The image reference is the only thing written to stdout, so `ref="$(scripts/package.sh)"`
# works; progress goes to stderr. Under GitHub Actions it is also written to $GITHUB_OUTPUT
# as `image`.

set -euo pipefail

image=""
tar_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="${2:?--image needs a value}"; shift 2 ;;
    --tar) tar_out="${2:?--tar needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { echo "$@" >&2; }

if [ -z "$image" ]; then
  image="$(basename "$PWD"):local"
fi
image="$(echo "$image" | tr '[:upper:]' '[:lower:]')"

ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT

if [ -f .output/server/index.mjs ]; then
  log "Serving as a Node server (.output)"
  cp -R .output "$ctx/.output"
  cat > "$ctx/Dockerfile" <<'DOCKERFILE'
FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
COPY .output ./.output
USER node
CMD ["node", ".output/server/index.mjs"]
DOCKERFILE
elif [ -f dist/index.html ]; then
  log "Serving as a static site (dist)"
  cp -R dist "$ctx/site"
  cat > "$ctx/default.conf" <<'NGINX'
server {
  listen 8080;
  root /usr/share/nginx/html;

  location / {
    try_files $uri $uri/ /index.html;
    add_header Cache-Control "no-cache";
  }

  location /assets/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
  }
}
NGINX
  cat > "$ctx/Dockerfile" <<'DOCKERFILE'
FROM nginxinc/nginx-unprivileged:1-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY site /usr/share/nginx/html
DOCKERFILE
else
  msg="The build produced neither .output/server/index.mjs nor dist/index.html."
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$msg" >&2; else echo "$msg" >&2; fi
  exit 1
fi

docker build --platform linux/amd64 --tag "$image" "$ctx" >&2

if [ -n "$tar_out" ]; then
  mkdir -p "$(dirname "$tar_out")"
  docker save "$image" | gzip > "$tar_out"
  log "Wrote $tar_out ($(du -h "$tar_out" | cut -f1))"
fi

log "Built $image"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "image=$image" >> "$GITHUB_OUTPUT"; fi
echo "$image"
