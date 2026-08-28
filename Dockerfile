# Two build stages and a small runtime. Nothing from the build survives into
# the image except the release itself.

FROM node:22-alpine AS client
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/tsconfig.json ./
COPY web/src ./src
RUN npx tsc --noEmit \
 && npx esbuild src/main.ts --bundle --format=esm --target=es2022 --minify --outfile=/app.js

FROM erlang:27-alpine AS build
WORKDIR /src
RUN apk add --no-cache git
COPY rebar.config rebar.lock ./
RUN rebar3 compile
COPY config config
COPY apps apps
COPY --from=client /app.js apps/fw_web/priv/static/app.js
RUN rebar3 as prod release

FROM alpine:3.21
RUN apk add --no-cache libstdc++ ncurses openssl \
 && adduser -D -h /app freewhen
WORKDIR /app
COPY --from=build /src/_build/prod/rel/freewhen ./
USER freewhen

# A room lives in this process's memory and nowhere else. Stopping the
# container is a data loss event by design; see docs/adr/0004.
ENV PORT=8080
EXPOSE 8080
CMD ["/app/bin/freewhen", "foreground"]
