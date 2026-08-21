using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
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

        services.AddSingleton<IEntityAllowList, ConfiguredEntityAllowList>();
        services.AddSingleton<IHaEventSource, HaEventSource>();

        // Именованный клиент: настройки таймаута и базового адреса
        // задаются пофайлово, а не глобально (AR-1.3).
        services.AddHttpClient<IHaClient, HaRestClient>(HttpClientName, ConfigureClient);
        services.AddHttpClient<HaProbe>(HttpClientName + "-probe", ConfigureClient);
        // Transient, не singleton: проба держит типизированный HttpClient,
        // а долгоживущая ссылка на него не переживает смену DNS.
        services.AddTransient<IComponentProbe>(sp => sp.GetRequiredService<HaProbe>());

        return services;
    }

    private static void ConfigureClient(IServiceProvider serviceProvider, HttpClient client)
    {
        HaOptions options = serviceProvider.GetRequiredService<IOptions<HaOptions>>().Value;

        client.BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + '/');
        client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
    }
}
