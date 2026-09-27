# Oqtane ships no image, only a release zip, so this is the whole build.
FROM debian:bookworm-slim AS fetch
ARG VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && curl -fsSL -o /oqtane.zip \
    "https://github.com/oqtane/oqtane.framework/releases/download/${VERSION}/Oqtane.Framework.${VERSION#v}.Install.zip" \
 && sha256sum /oqtane.zip > /artifact.sha256 \
 && mkdir /app \
 # The zip is made on Windows: unzip converts its backslashes and exits 1 to warn.
 && { unzip -q /oqtane.zip -d /app || [ $? -eq 1 ]; } \
 && test -f /app/Oqtane.Server.dll && test -f /app/runtimes/linux-arm64/native/libe_sqlite3.so \
 # Its folders arrive without read or enter rights, which only root without
 # dropped capabilities could ignore.
 && chmod -R u+rwX,go+rX /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
COPY --from=fetch /app /app
# What upstream_build.sh pins this version to.
COPY --from=fetch /artifact.sha256 /upstream-artifact.sha256
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Oqtane.Server.dll"]
