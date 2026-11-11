using System.Globalization;
using System.Net;
using System.Security.Claims;
using System.Threading.RateLimiting;
using Domovoy.Api.Endpoints;
using Domovoy.Core.Configuration;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace Domovoy.Api.Security;

/// <summary>
/// Ограничение частоты запросов (NFR-SEC-3) — один <c>AddRateLimiter</c> на
/// хост и один обработчик отказа на все лимиты. Окно всех лимитов —
/// фиксированная минута, очереди нет.
///
/// Глобальный лимитер стоит на каждом маршруте, включая <c>/health</c>.
/// Раздел вычисляется из уже установленной личности и конечной точки, а не
/// из заголовков запроса (запись 0035): устройство по своему id,
/// администратор, петля контейнера (healthcheck и проверка обновления) и
/// каждая анонимная конечная точка отдельно — поток к <c>/health</c> не
/// закрывает обмен кода привязки. Подделываемого ключа нет, поэтому число
/// разделов ограничено числом устройств и конечных точек. Лимитер стоит
/// после авторизации: запрос без действующего токена получает 401 до него
/// и раздел не тратит — цена названа в 0035.
///
/// Политика <see cref="DeviceTokenDefaults.LlmRateLimitPolicy"/> на
/// <c>/chat</c> и <c>/voice</c> — один раздел на дом: бюджет токенов один
/// (NFR-COST-2). Политика <see cref="DeviceTokenDefaults.PairingRateLimitPolicy"/>
/// — один раздел на обмен кода привязки, как в записи 0033.
///
/// Пределы читаются из опций собранного хоста на первом запросе раздела, а
/// не до Build: иначе перекрытия конфигурации тестов до лимитера не дошли
/// бы. Метрика срабатывания — встроенный счётчик ASP.NET Core
/// <c>aspnetcore.rate_limiting.requests</c>; своего нет.
/// </summary>
internal static class ApiRateLimits
{
    private const string PairingPartitionKey = "pairing";
    private const string LlmPartitionKey = "llm";
    private const string UnmatchedEndpoint = "unmatched";

    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    public static IServiceCollection AddApiRateLimits(this IServiceCollection services)
    {
        services.AddOptions<RateLimitOptions>()
            .BindConfiguration(RateLimitOptions.SectionName)
            .ValidateDataAnnotations()
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<RateLimitOptions>, RateLimitOptionsValidator>();

        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(context =>
            {
                int permitLimit = context.RequestServices
                    .GetRequiredService<IOptions<RateLimitOptions>>().Value.RequestsPerMinute;

                return FixedWindow(ResolvePartition(context).Key, permitLimit);
            });

            options.AddPolicy(DeviceTokenDefaults.LlmRateLimitPolicy, context =>
            {
                int permitLimit = context.RequestServices
                    .GetRequiredService<IOptions<RateLimitOptions>>().Value.LlmRequestsPerMinute;

                return FixedWindow(LlmPartitionKey, permitLimit);
            });

            options.AddPolicy(DeviceTokenDefaults.PairingRateLimitPolicy, context =>
            {
                int permitLimit = context.RequestServices
                    .GetRequiredService<IOptions<AuthOptions>>().Value.PairingAttemptsPerMinute;

                return FixedWindow(PairingPartitionKey, permitLimit);
            });

            options.OnRejected = OnRejectedAsync;
        });

        return services;
    }

    private static RateLimitPartition<string> FixedWindow(string key, int permitLimit) =>
        RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = permitLimit,
            Window = Window,
            QueueLimit = 0,
            AutoReplenishment = true,
        });

    /// <summary>
    /// Раздел глобального лимита: вид (в лог) и ключ. Ключ — только из
    /// установленной личности, адреса петли и имени конечной точки; ни
    /// одного значения из заголовков запроса.
    /// </summary>
    private static (string Kind, string Key) ResolvePartition(HttpContext context)
    {
        foreach (ClaimsIdentity identity in context.User.Identities)
        {
            if (!identity.IsAuthenticated)
            {
                continue;
            }

            if (identity.AuthenticationType == DeviceTokenDefaults.SchemeName
                && identity.FindFirst(ClaimTypes.NameIdentifier)?.Value is { Length: > 0 } deviceId)
            {
                return ("device", "device:" + deviceId);
            }

            if (identity.AuthenticationType == DeviceTokenDefaults.AdminSchemeName)
            {
                return ("admin", "admin");
            }
        }

        if (IsLoopback(context.Connection.RemoteIpAddress))
        {
            return ("local", "local");
        }

        Endpoint? endpoint = context.GetEndpoint();
        string endpointName = endpoint?.Metadata.GetMetadata<IEndpointNameMetadata>()?.EndpointName
            ?? endpoint?.DisplayName
            ?? UnmatchedEndpoint;

        return ("anonymous", "anonymous:" + endpointName);
    }

    private static bool IsLoopback(IPAddress? address)
    {
        if (address is null)
        {
            return false;
        }

        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        return IPAddress.IsLoopback(address);
    }

    /// <summary>
    /// 429 в едином формате с Retry-After из метаданных аренды. В лог —
    /// Warning с маршрутом и видом раздела, без id устройства, заголовков и
    /// тела запроса: код привязки и токен не логируются никогда. Событие
    /// пишется внутри области запроса и несёт его RequestId.
    /// </summary>
    private static async ValueTask OnRejectedAsync(OnRejectedContext context, CancellationToken cancellationToken)
    {
        HttpContext httpContext = context.HttpContext;

        TimeSpan retryAfter = context.Lease.TryGetMetadata(MetadataName.RetryAfter, out TimeSpan fromLease)
            ? fromLease
            : Window;
        int seconds = Math.Clamp((int)Math.Ceiling(retryAfter.TotalSeconds), 1, (int)Window.TotalSeconds);

        httpContext.Response.Headers.RetryAfter = seconds.ToString(CultureInfo.InvariantCulture);

        httpContext.RequestServices
            .GetRequiredService<ILoggerFactory>()
            .CreateLogger(typeof(ApiRateLimits).FullName!)
            .LogWarning(
                "Запрос отклонён лимитером частоты: маршрут {RateLimitEndpoint}, раздел {RateLimitPartition}.",
                httpContext.GetEndpoint()?.DisplayName ?? UnmatchedEndpoint,
                ResolvePartition(httpContext).Kind);

        await ApiErrorResults.Write(
            httpContext,
            StatusCodes.Status429TooManyRequests,
            ApiErrorResults.RateLimited,
            "Слишком много запросов. Повторите позже.");
    }
}
