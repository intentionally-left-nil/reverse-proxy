FROM nginx:mainline-alpine
ARG acme_version=3.0.6

RUN apk update && apk add --no-cache curl openssl jq git
RUN git clone --depth 1 --branch "$acme_version" https://github.com/acmesh-official/acme.sh.git /opt/acme.sh
COPY bootstrap.sh /docker-entrypoint.d/00-bootstrap.sh
COPY init.sh /docker-entrypoint.d/01-init.sh
RUN find /docker-entrypoint.d/ -type f -iname "*.sh" -exec chmod +x {} \;
