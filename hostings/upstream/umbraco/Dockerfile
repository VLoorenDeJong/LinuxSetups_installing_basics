# Umbraco ships no image and no runnable release, only a project template on
# NuGet, so the build makes a fresh site from the template at VERSION.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG VERSION
RUN dotnet new install "Umbraco.Templates::${VERSION}" \
 && sha256sum "/root/.templateengine/packages/Umbraco.Templates.${VERSION}.nupkg" > /artifact.sha256
WORKDIR /src
RUN dotnet new umbraco -n Site && dotnet publish Site -c Release -o /app \
 # Templates are files Umbraco writes into Views, which is a mount on the
 # machine; the shipped ones are copied into it at start.
 && mv /app/Views /app/Views.dist && mkdir /app/Views

FROM mcr.microsoft.com/dotnet/aspnet:10.0
COPY --from=build /app /app
# What upstream_build.sh pins this version to.
COPY --from=build /artifact.sha256 /upstream-artifact.sha256
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "cp -rn /app/Views.dist/. /app/Views/ && exec dotnet Site.dll"]
