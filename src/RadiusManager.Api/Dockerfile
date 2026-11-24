FROM node:22-bookworm-slim AS ui-build
WORKDIR /ui/frontend
COPY frontend/package.json frontend/tsconfig.json frontend/vite.config.ts ./
RUN npm install --no-audit --no-fund --ignore-scripts
COPY frontend/src ./src
RUN npm run check && npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY RadiusManager.Api.csproj ./
RUN dotnet restore
COPY . ./
COPY --from=ui-build /ui/wwwroot/modern ./wwwroot/modern
RUN dotnet publish -c Release --no-restore -o /app/out
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/out ./
# Empty Docker volumes copy this directory's secure ownership on first mount.
RUN mkdir -p /var/lib/radius-admin-keys \
    && chown "$APP_UID:$APP_UID" /var/lib/radius-admin-keys \
    && chmod 700 /var/lib/radius-admin-keys
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "RadiusManager.Api.dll"]
