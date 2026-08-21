using System.Net;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Domovoy.Llm;

/// <summary>Регистрация слоя LLM.</summary>
public static class LlmServiceCollectionExtensions
{
    /// <summary>Именованный HTTP-клиент слоя.</summary>
    public const string HttpClientName = "llm";

    public static IServiceCollection AddLlm(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        // Провайдер выбирается по диалекту из конфигурации. Ветвление
        // одно и находится здесь, в точке регистрации: код за пределами
        // слоя адаптера о провайдере не знает.
        services.AddHttpClient<OpenAiCompatibleLlmProvider>(HttpClientName, ConfigureClient)
            .ConfigurePrimaryHttpMessageHandler(CreateHandler);
        services.AddHttpClient<YandexLlmProvider>(HttpClientName + "-yandex", ConfigureClient)
            .ConfigurePrimaryHttpMessageHandler(CreateHandler);

        services.AddSingleton<ILlmProvider>(serviceProvider =>
        {
            LlmOptions options = serviceProvider.GetRequiredService<IOptions<LlmOptions>>().Value;

            return options.Dialect switch
            {
                LlmDialect.Yandex => serviceProvider.GetRequiredService<YandexLlmProvider>(),
                _ => serviceProvider.GetRequiredService<OpenAiCompatibleLlmProvider>(),
            };
        });

        services.AddHttpClient<LlmProbe>(HttpClientName + "-probe", ConfigureClient)
            .ConfigurePrimaryHttpMessageHandler(CreateHandler);
        services.AddTransient<IComponentProbe>(sp => sp.GetRequiredService<LlmProbe>());

        return services;
    }

    private static void ConfigureClient(IServiceProvider serviceProvider, HttpClient client)
    {
        LlmOptions options = serviceProvider.GetRequiredService<IOptions<LlmOptions>>().Value;

        client.BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + '/');
        client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
    }

    /// <summary>
    /// Прокси задаётся пофайлово для этого клиента, а не для процесса:
    /// маршрутизация хоста не трогается никогда — full tunnel ломает
    /// сборку и диагностику (AR-1.3).
    /// </summary>
    private static HttpMessageHandler CreateHandler(IServiceProvider serviceProvider)
    {
        LlmOptions options = serviceProvider.GetRequiredService<IOptions<LlmOptions>>().Value;
        var handler = new HttpClientHandler();

        if (!PlaceholderValues.IsUnset(options.Proxy))
        {
            handler.Proxy = new WebProxy(options.Proxy);
            handler.UseProxy = true;
        }

        return handler;
    }
}
