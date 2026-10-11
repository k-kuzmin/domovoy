using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.EnvironmentVariables;
using Microsoft.Extensions.Configuration.Json;

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
/// appsettings.json из репозитория плюс явные перекрытия самих тестов.
/// </summary>
public sealed class DomovoyApiFactory : WebApplicationFactory<Program>
{
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
        });
    }

    /// <summary>
    /// Источник принадлежит машине разработчика: user-secrets или
    /// переменные окружения без префикса. Префиксные переменные
    /// (<c>ASPNETCORE_</c>, <c>DOTNET_</c>) — настройки хоста, а не
    /// приложения, и секретов в них нет.
    /// </summary>
    internal static bool IsMachineSource(IConfigurationSource source) => source switch
    {
        EnvironmentVariablesConfigurationSource environment => string.IsNullOrEmpty(environment.Prefix),
        JsonConfigurationSource json => string.Equals(json.Path, "secrets.json", StringComparison.OrdinalIgnoreCase),
        _ => false,
    };
}
