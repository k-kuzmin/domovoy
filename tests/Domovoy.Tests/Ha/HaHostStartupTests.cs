using Domovoy.Core.Abstractions;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.Registry;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Слой Home Assistant на настоящей регистрации DI (#9, #10): реестр
/// проверяется на старте хоста, а службы слоя разрешаются из собранного
/// приложения и делят один кэш и один статус соединения с воркером.
///
/// Хосты здесь собираются построителем без источников по умолчанию: обычный
/// построитель читает переменные окружения машины, и токен разработчика
/// дошёл бы до воркера. Конфигурация — appsettings.json из репозитория плюс
/// явные перекрытия теста.
/// </summary>
public sealed class HaHostStartupTests : IDisposable
{
    private static readonly string ExamplePath = RepositoryLayout.Path("config", "entities.example.yaml");

    private readonly DirectoryInfo _workDirectory =
        Directory.CreateTempSubdirectory("domovoy-host-");

    public void Dispose() => _workDirectory.Delete(recursive: true);

    public static TheoryData<string, string, string> InvalidRegistries => new()
    {
        {
            // Домен вне закрытого перечня каталога.
            "  - entity_id: cover.example_hall_blinds\n    name: Шторы\n    area: living_room\n    domain: cover\n    actions: [open_cover]\n",
            "cover.example_hall_blinds",
            "domain"
        },
        {
            // Нет обязательного поля name.
            "  - entity_id: light.example_hall\n    area: living_room\n    domain: light\n    actions: [turn_on]\n",
            "light.example_hall",
            "name"
        },
    };

    [Theory(DisplayName = "Хост не стартует на реестре с неизвестным доменом или без обязательного поля")]
    [MemberData(nameof(InvalidRegistries))]
    public async Task HostRefusesToStartOnInvalidRegistry(string injectedEntity, string entityId, string field)
    {
        string path = WriteExampleWith(injectedEntity);
        using IHost host = BuildHost(path);

        Func<Task> start = () => host.StartAsync();

        // Тип опций и запись в сообщении — иначе отказ любой другой опции
        // на этой конфигурации выглядел бы так же.
        OptionsValidationException exception = (await start.Should().ThrowAsync<OptionsValidationException>()).Which;
        exception.OptionsType.Should().Be<EntityRegistryOptions>();
        exception.Message.Should().Contain(entityId).And.Contain(field);
    }

    [Fact(DisplayName = "На примере реестра хост стартует и останавливается")]
    public async Task HostStartsOnExampleRegistry()
    {
        using IHost host = BuildHost(ExamplePath);

        await host.StartAsync();

        host.Services.GetRequiredService<IEntityAllowList>().All.Should().NotBeEmpty();
        host.Services.GetRequiredService<HaConnectionState>().Status
            .Should().Be(HaConnectionStatus.NotConfigured, "в appsettings.json токена нет");

        await host.StopAsync();
    }

    [Fact(DisplayName = "Службы слоя HA разрешаются из приложения и делят кэш и статус с воркером")]
    public async Task HaServicesResolveFromApplication()
    {
        using var factory = new DomovoyApiFactory();
        IServiceProvider services = factory.Services;

        services.GetRequiredService<IEntityAllowList>().All.Should().NotBeEmpty("фабрика указывает на пример реестра");
        services.GetRequiredService<IFastPath>().Should().NotBeNull();
        services.GetRequiredService<IHaEventSource>()
            .Should().BeSameAs(services.GetRequiredService<HaEventSource>(), "воркер публикует в тот же раздатчик, что читают подписчики");
        services.GetServices<IHostedService>().OfType<HaWebSocketWorker>().Should().ContainSingle();

        // Клиент читает тот же кэш, что наполняет воркер: при Connected
        // GetStatesAsync отдаёт кэш, в сеть не идёт.
        var state = new HaEntityState
        {
            EntityId = "light.example_kitchen_ceiling",
            State = "on",
            Attributes = new Dictionary<string, string>(),
            LastChanged = DateTimeOffset.UnixEpoch,
            LastUpdated = DateTimeOffset.UnixEpoch,
        };
        services.GetRequiredService<HaStateCache>().ReplaceAll([state]);
        services.GetRequiredService<HaConnectionState>().Set(HaConnectionStatus.Connected);

        IReadOnlyList<HaEntityState> states = await services.GetRequiredService<IHaClient>()
            .GetStatesAsync(area: null, domain: "light", CancellationToken.None);

        states.Should().ContainSingle().Which.Should().BeSameAs(state);
    }

    private static IHost BuildHost(string registryPath)
    {
        HostApplicationBuilder builder = Host.CreateEmptyApplicationBuilder(new HostApplicationBuilderSettings
        {
            EnvironmentName = Environments.Development,
            ContentRootPath = Path.GetTempPath(),
        });

        builder.Configuration
            .AddJsonFile(RepositoryLayout.Path("src", "Domovoy.Api", "appsettings.json"))
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Ha:EntityRegistryPath"] = registryPath,
                ["Ha:BaseUrl"] = DomovoyApiFactory.UnreachableHaBaseUrl,
            });

        builder.Services.AddLogging();
        builder.Services.AddDomovoyCore(builder.Configuration);
        builder.Services.AddHomeAssistant();

        return builder.Build();
    }

    /// <summary>Пример реестра со вставкой в конец раздела entities.</summary>
    private string WriteExampleWith(string injectedEntity)
    {
        string example = File.ReadAllText(ExamplePath).ReplaceLineEndings("\n");
        string content = example.Replace("\nscripts:", "\n" + injectedEntity + "\nscripts:", StringComparison.Ordinal);
        content.Should().NotBe(example, "вставка должна попасть в файл");

        string path = Path.Combine(_workDirectory.FullName, "entities.yaml");
        File.WriteAllText(path, content);
        return path;
    }
}
