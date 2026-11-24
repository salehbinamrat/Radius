FROM node:24-bookworm-slim AS ui-build
WORKDIR /ui/frontend
COPY frontend/package.json frontend/tsconfig.json frontend/vite.config.ts ./
RUN npm install --no-audit --no-fund --ignore-scripts
COPY frontend/src ./src
# The React planner imports the existing shared pure JS calculator and its TS types.
COPY wwwroot/capacity-utils.mjs wwwroot/capacity-utils.d.mts /ui/wwwroot/
COPY wwwroot/live-status-model.mjs wwwroot/live-status-model.d.mts /ui/wwwroot/
COPY wwwroot/service-history-model.mjs wwwroot/service-history-model.d.mts /ui/wwwroot/
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
    && chmod 700 /var/lib/radius-admin-keys \
    && mkdir -p /var/lib/radius-service-history \
    && chown "$APP_UID:$APP_UID" /var/lib/radius-service-history \
    && chmod 700 /var/lib/radius-service-history
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "RadiusManager.Api.dll"]
