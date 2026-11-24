FROM node:24-bookworm-slim@sha256:873f586f3794f52281bd039bf02c048a0be08fde619338f9941bad1eb6b34530 AS ui-build
WORKDIR /ui/frontend
COPY frontend/package.json frontend/package-lock.json frontend/tsconfig.json frontend/vite.config.ts ./
RUN npm ci --no-audit --no-fund --ignore-scripts
COPY frontend/src ./src
# The React planner imports the existing shared pure JS calculator and its TS types.
COPY wwwroot/capacity-utils.mjs wwwroot/capacity-utils.d.mts /ui/wwwroot/
COPY wwwroot/live-status-model.mjs wwwroot/live-status-model.d.mts /ui/wwwroot/
COPY wwwroot/service-history-model.mjs wwwroot/service-history-model.d.mts /ui/wwwroot/
COPY wwwroot/service-alert-model.mjs wwwroot/service-alert-model.d.mts /ui/wwwroot/
RUN npm run check && npm run build

FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:8c6edfb26c85153f236d26efebd9ad349aec403583f343f201ee67838b23658d AS build
WORKDIR /src
COPY RadiusManager.Api.csproj packages.lock.json ./
RUN dotnet restore --locked-mode
COPY . ./
COPY --from=ui-build /ui/wwwroot/modern ./wwwroot/modern
RUN dotnet publish -c Release --no-restore -o /app/out
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:aac50ceef10391e78a899e3d2ccd00bbafa2dcb56ccf4586cbccf00edb84fc21
WORKDIR /app
COPY --from=build /app/out ./
# Empty Docker volumes copy this directory's secure ownership on first mount.
RUN mkdir -p /var/lib/radius-admin-keys \
    && chown "$APP_UID:$APP_UID" /var/lib/radius-admin-keys \
    && chmod 700 /var/lib/radius-admin-keys \
    && mkdir -p /var/lib/radius-service-history \
    && chown "$APP_UID:$APP_UID" /var/lib/radius-service-history \
    && chmod 700 /var/lib/radius-service-history
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "RadiusManager.Api.dll"]
