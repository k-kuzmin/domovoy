using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Domovoy.Notifications;

/// <summary>Регистрация слоя уведомлений и проактивности.</summary>
public static class NotificationsServiceCollectionExtensions
{
    public const string HttpClientName = "ntfy";

    public static IServiceCollection AddNotifications(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddHttpClient<IPushSender, NtfyPushSender>(
            HttpClientName,
            (serviceProvider, client) =>
            {
                NtfyOptions options = serviceProvider.GetRequiredService<IOptions<NtfyOptions>>().Value;
                client.BaseAddress = new Uri(options.BaseUrl.TrimEnd('/') + '/');
                client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
            });

        services.AddSingleton<IProactiveRuleEngine, DeclarativeProactiveRuleEngine>();
        services.AddHostedService<ProactivityWorker>();

        return services;
    }
}
