using System.Globalization;
using System.Threading.RateLimiting;
using Domovoy.Api.Endpoints;
using Domovoy.Core.Configuration;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Ограничение частоты обмена кода привязки на токен — вторая мера границы
/// записи 0025: «Перебор кодов обязан упираться в лимит обращений к
/// эндпоинту».
///
/// Раздел один на весь эндпоинт, а не по адресу источника: за туннелем
/// адрес у всех запросов один, а раздел по заголовку обходится его
/// подделкой — порт api опубликован на хост. Цена названа в записи 0033:
/// тот, кто прошёл внешний периметр, может отложить чужую привязку до
/// конца окна.
///
/// Предел читается из <see cref="AuthOptions"/> собранного хоста на первом
/// запросе, а не до Build: иначе перекрытия конфигурации тестов до лимитера
/// не дошли бы.
/// </summary>
internal static class PairingRateLimit
{
    private const string PartitionKey = "pairing";

    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    public static IServiceCollection AddPairingRateLimit(this IServiceCollection services)
    {
        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            options.AddPolicy(DeviceTokenDefaults.PairingRateLimitPolicy, context =>
            {
                int permitLimit = context.RequestServices
                    .GetRequiredService<IOptions<AuthOptions>>().Value.PairingAttemptsPerMinute;

                return RateLimitPartition.GetFixedWindowLimiter(PartitionKey, _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = permitLimit,
                    Window = Window,
                    QueueLimit = 0,
                    AutoReplenishment = true,
                });
            });

            options.OnRejected = OnRejectedAsync;
        });

        return services;
    }

    /// <summary>
    /// 429 в едином формате с Retry-After из метаданных аренды. В лог —
    /// Warning без тела запроса: код привязки не логируется никогда.
    /// </summary>
    private static async ValueTask OnRejectedAsync(OnRejectedContext context, CancellationToken cancellationToken)
    {
        TimeSpan retryAfter = context.Lease.TryGetMetadata(MetadataName.RetryAfter, out TimeSpan fromLease)
            ? fromLease
            : Window;
        int seconds = Math.Clamp((int)Math.Ceiling(retryAfter.TotalSeconds), 1, (int)Window.TotalSeconds);

        context.HttpContext.Response.Headers.RetryAfter = seconds.ToString(CultureInfo.InvariantCulture);

        context.HttpContext.RequestServices
            .GetRequiredService<ILoggerFactory>()
            .CreateLogger(typeof(PairingRateLimit).FullName!)
            .LogWarning("Обмен кода привязки отклонён: превышен предел обращений в минуту.");

        await ApiErrorResults.Write(
            context.HttpContext,
            StatusCodes.Status429TooManyRequests,
            ApiErrorResults.RateLimited,
            "Слишком много попыток привязки. Повторите позже.");
    }
}
