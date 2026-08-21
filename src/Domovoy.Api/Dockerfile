# ============================================================
# Домовой — образ Backend
#
# Контекст сборки — корень репозитория: Directory.Build.props и
# Directory.Packages.props лежат там, без них восстановление пакетов не
# работает.
#
#   docker build -f src/Domovoy.Api/Dockerfile .
# ============================================================

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Сначала только файлы проектов: слой с восстановленными пакетами
# переиспользуется, пока не изменились зависимости.
COPY global.json Directory.Build.props Directory.Packages.props Domovoy.sln ./
COPY src/Domovoy.Api/Domovoy.Api.csproj                     src/Domovoy.Api/
COPY src/Domovoy.Core/Domovoy.Core.csproj                   src/Domovoy.Core/
COPY src/Domovoy.Ha/Domovoy.Ha.csproj                       src/Domovoy.Ha/
COPY src/Domovoy.Llm/Domovoy.Llm.csproj                     src/Domovoy.Llm/
COPY src/Domovoy.Voice/Domovoy.Voice.csproj                 src/Domovoy.Voice/
COPY src/Domovoy.Notifications/Domovoy.Notifications.csproj src/Domovoy.Notifications/
COPY src/Domovoy.Data/Domovoy.Data.csproj                   src/Domovoy.Data/
COPY tests/Domovoy.Tests/Domovoy.Tests.csproj               tests/Domovoy.Tests/
RUN dotnet restore Domovoy.sln

COPY . .
RUN dotnet publish src/Domovoy.Api/Domovoy.Api.csproj \
        --configuration Release \
        --no-restore \
        --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

# curl нужен для healthcheck контейнера: в образе aspnet его нет.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/publish ./

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Непривилегированный пользователь есть в образе .NET 8 (UID 1654).
USER $APP_UID

ENTRYPOINT ["dotnet", "Domovoy.Api.dll"]
