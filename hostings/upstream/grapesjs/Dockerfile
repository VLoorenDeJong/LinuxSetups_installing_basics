# GrapesJS is a library, not an application, so this image is the smallest
# wrapper that makes it one: its release files plus one page, served by nginx.
FROM node:24-alpine AS fetch
ARG VERSION
WORKDIR /p
# The blocks plugin is fixed: a moving version would break the pin.
RUN npm pack "grapesjs@${VERSION}" grapesjs-blocks-basic@1.0.2 \
 && sha256sum *.tgz | sha256sum > /artifact.sha256 \
 && mkdir core blocks \
 && tar xzf "grapesjs-${VERSION}.tgz" -C core \
 && tar xzf grapesjs-blocks-basic-*.tgz -C blocks

FROM nginx:alpine
COPY --from=fetch /p/core/package/dist /usr/share/nginx/html/grapesjs
COPY --from=fetch /p/blocks/package/dist /usr/share/nginx/html/blocks
# What upstream_build.sh pins this version to.
COPY --from=fetch /artifact.sha256 /upstream-artifact.sha256
COPY index.html /usr/share/nginx/html/index.html
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --chmod=755 40-own-data.sh /docker-entrypoint.d/40-own-data.sh
EXPOSE 8080
