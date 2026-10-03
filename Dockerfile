FROM alpine:3.22 AS builder

WORKDIR /src

# hugo from edge/community; node/npm for pagefind
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    hugo \
    nodejs npm

COPY . .

RUN hugo --minify

# Pagefind indexes the built HTML into public/pagefind/
RUN npx --yes pagefind --site public

# Pre-compress text assets for nginx gzip_static
RUN find public -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' \) -exec gzip -kf {} +

FROM nginx:1.27-alpine AS runner
COPY --from=builder /src/public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf
