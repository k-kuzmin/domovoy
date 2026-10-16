# ============================================================
# Домовой — образ Backend
#
# Контекст сборки — корень репозитория: Directory.Build.props и
# Directory.Packages.props лежат там, без них восстановление пакетов не
# работает.
#
#   docker build -f src/Domovoy.Api/Dockerfile .
#   docker build -f src/Domovoy.Api/Dockerfile --target migrate .
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
COPY tests/Domovoy.Tests.LiveCheck/Domovoy.Tests.LiveCheck.csproj tests/Domovoy.Tests.LiveCheck/
RUN dotnet restore Domovoy.sln

COPY . .
RUN dotnet publish src/Domovoy.Api/Domovoy.Api.csproj \
        --configuration Release \
        --no-restore \
        --output /app/publish

# Идемпотентный SQL-скрипт миграций: образ migrate применяет его psql, без
# SDK и без исходников. Версия dotnet-ef — та же, что EF Core в
# Directory.Packages.props (#162). --no-transactions: своих START
# TRANSACTION/COMMIT в скрипте нет, транзакцию держит psql в образе migrate.
FROM build AS migrations
RUN dotnet tool install --tool-path /tools dotnet-ef --version 8.0.11
RUN /tools/dotnet-ef migrations script \
        --idempotent \
        --no-transactions \
        --output /out/migrate.sql \
        --project src/Domovoy.Data \
        --startup-project src/Domovoy.Api \
        --configuration Release

# Образ применения миграций: только psql и скрипт. Подключение — переменные
# PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD из окружения; значений в
# образе нет. Весь скрипт — одна транзакция psql (--single-transaction),
# первая ошибка (ON_ERROR_STOP) откатывает её целиком.
FROM postgres:16-alpine AS migrate
COPY --from=migrations /out/migrate.sql /migrations/migrate.sql
ENTRYPOINT ["psql", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-f", "/migrations/migrate.sql"]

# runtime — последняя стадия и цель сборки по умолчанию.
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
