using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Ha.Registry;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>Регистрация слоя Home Assistant.</summary>
public static class HaServiceCollectionExtensions
{
    /// <summary>Именованный HTTP-клиент слоя.</summary>
    public const string HttpClientName = "ha";

    public static IServiceCollection AddHomeAssistant(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        // Реестр сущностей (FR-HA-4, FR-HA-5): читается из файла и
        // проверяется на старте — реестр с ошибкой не запускает сервис.
        services.AddOptions<EntityRegistryOptions>().ValidateOnStart();
        services.AddSingleton<IConfigureOptions<EntityRegistryOptions>, EntityRegistryFileLoader>();
        services.AddSingleton<IValidateOptions<EntityRegistryOptions>, EntityRegistryValidator>();
        services.AddSingleton<IEntityAllowList, ConfiguredEntityAllowList>();

        // Состояния (FR-HA-3): один кэш, один статус соединения и один
        // раздатчик событий на процесс — их пишет воркер, читают клиент,
        // проба и подписчики. Раздатчик регистрируется конкретным типом и
        // отдаётся портом из того же экземпляра: два экземпляра значили бы,
        // что воркер публикует туда, где никто не слушает.
        services.AddSingleton<HaStateCache>();
        services.AddSingleton<HaConnectionState>();
        services.AddSingleton<HaEventSource>();
        services.AddSingleton<IHaEventSource>(sp => sp.GetRequiredService<HaEventSource>());
        services.AddSingleton<IReconnectDelay, SystemReconnectDelay>();
        services.AddSingleton(new HaWebSocketTimings());
        services.AddHostedService<HaWebSocketWorker>();

        // Именованный клиент: настройки таймаута и базового адреса
        // задаются пофайлово, а не глобально (AR-1.3).
        services.AddHttpClient<IHaClient, HaRestClient>(HttpClientName, ConfigureClient);
        // Тот же именованный клиент берёт воркер для опроса REST во время
        // паузы реконнекта (HaWebSocketWorker.ProbeClientName).
        services.AddHttpClient<HaProbe>(HaWebSocketWorker.ProbeClientName, ConfigureClient);
        // Transient, не singleton: проба держит типизированный HttpClient,
        // а долгоживущая ссылка на него не переживает смену DNS.
        services.AddTransient<IComponentProbe>(sp => sp.GetRequiredService<HaProbe>());
        // Проба WebSocket только читает статус воркера: HTTP-клиента у неё нет.
        services.AddSingleton<IComponentProbe, HaWebSocketProbe>();

        return services;
    }

    private static void ConfigureClient(IServiceProvider serviceProvider, HttpClient client)
    {
        HaOptions options = serviceProvider.GetRequiredService<IOptions<HaOptions>>().Value;

        client.BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + '/');
        client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
    }
}
