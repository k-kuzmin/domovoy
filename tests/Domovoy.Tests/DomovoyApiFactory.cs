using Domovoy.Core.Abstractions;
using Domovoy.Tests.Auth;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.EnvironmentVariables;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Domovoy.Tests;

/// <summary>
/// Фабрика приложения для всех тестов, которые его поднимают.
///
/// <c>WebApplicationFactory</c> по умолчанию запускает хост в окружении
/// Development, а <c>WebApplication.CreateBuilder</c> в Development читает
/// user-secrets разработчика, а в любом окружении — переменные окружения
/// машины. Без этой фабрики тесты видят настоящий токен Home Assistant и
/// ключ LLM того, кто их запускает: результат зависит от машины, а пробы
/// ходят в сеть с его учётными данными.
///
/// Окружение остаётся Development: на нём хост включает проверку DI-графа
/// при сборке (ValidateOnBuild, ValidateScopes), и смена окружения молча
/// сняла бы её со всех тестов. Убираются только два источника, которые
/// принадлежат машине, а не репозиторию. Конфигурация тестов — это
/// appsettings.json из репозитория плюс явные перекрытия самих тестов —
/// для значений, читаемых из собранного хоста (options, IConfiguration
/// после Build). То, что Program.cs читает до Build, — строка
/// подключения — этой фабрикой не перекрывается.
///
/// Перекрытия поверх appsettings.json — <see cref="RepositoryOverrides"/>:
/// реестр сущностей — пример из репозитория по абсолютному пути (реестр
/// проверяется на старте, а относительный путь считался бы от каталога
/// проекта Api, где файла нет), и адрес Home Assistant — закрытый порт на
/// loopback. Хост держит WebSocket-воркер; тест, задавший токен, запускает
/// его цикл реконнекта, и с адресом из appsettings.json воркер шёл бы в DNS
/// машины за именем <c>homeassistant</c> — в сети разработчика оно может
/// оказаться его настоящим HA, и туда ушёл бы тестовый токен. Тесты, которым
/// нужен ответ HA, подменяют обработчик своего HTTP-клиента; адрес на это
/// не влияет.
///
/// Хранилище устройств подменено <see cref="InMemoryDeviceStore"/>: с
/// настоящим EF-хранилищем любой запрос с Bearer шёл бы в Postgres. Фейк один
/// на фабрику — и на хосты, порождённые из неё <c>WithWebHostBuilder</c>, —
/// и доступен тестам через <see cref="Store"/>. Предел обменов кода
/// привязки поднят: лимитер общий на хост, и тесты класса, обменивающие
/// коды, иначе упёрлись бы в него вне теста самого лимита. Админ-секрет
/// фабрика не задаёт: админка по умолчанию закрыта, тест, которому она
/// нужна, задаёт секрет сам.
/// </summary>
public sealed class DomovoyApiFactory : WebApplicationFactory<Program>
{
    /// <summary>Хранилище устройств всех хостов этой фабрики.</summary>
    public InMemoryDeviceStore Store { get; } = new();

    /// <summary>
    /// Адрес, на котором никто не слушает: порт 9 (discard) на loopback.
    /// Соединение отклоняется без выхода в сеть.
    /// </summary>
    internal const string UnreachableHaBaseUrl = "http://127.0.0.1:9";

    /// <summary>Перекрытия конфигурации, общие для всех тестов приложения.</summary>
    internal static IReadOnlyDictionary<string, string?> RepositoryOverrides { get; } =
        new Dictionary<string, string?>
        {
            ["Ha:EntityRegistryPath"] = RepositoryLayout.Path("config", "entities.example.yaml"),
            ["Ha:BaseUrl"] = UnreachableHaBaseUrl,
            ["Auth:PairingAttemptsPerMinute"] = "1000",
        };

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        ArgumentNullException.ThrowIfNull(builder);

        builder.ConfigureAppConfiguration((_, configuration) =>
        {
            for (int index = configuration.Sources.Count - 1; index >= 0; index--)
            {
                if (IsMachineSource(configuration.Sources[index]))
                {
                    configuration.Sources.RemoveAt(index);
                }
            }

            configuration.AddInMemoryCollection(RepositoryOverrides);
        });

        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IDeviceStore>();
            services.AddSingleton<IDeviceStore>(Store);
        });
    }

    /// <summary>
    /// Источник принадлежит машине разработчика: user-secrets или
    /// переменные окружения без префикса. Префиксные переменные
    /// (<c>ASPNETCORE_</c>, <c>DOTNET_</c>) остаются: через них хост
    /// получает свои настройки. Префикс при чтении отрезается, поэтому
    /// ключ приложения, заданный машине с таким префиксом, до тестов
    /// дойдёт — это не защищается, а принимается.
    /// </summary>
    internal static bool IsMachineSource(IConfigurationSource source) => source switch
    {
        EnvironmentVariablesConfigurationSource environment => string.IsNullOrEmpty(environment.Prefix),
        JsonConfigurationSource json => string.Equals(json.Path, "secrets.json", StringComparison.OrdinalIgnoreCase),
        _ => false,
    };
}
