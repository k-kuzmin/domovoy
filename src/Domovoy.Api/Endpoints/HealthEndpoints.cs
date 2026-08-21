using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Эндпоинты проверки состояния.
///
/// Их два, и это осознанное решение. ТЗ помещает <c>/health</c> под
/// <c>/api/v1</c> с Bearer-токеном, но healthcheck контейнера и туннель
/// ходят без токена, а требование «поднимается на .example-конфигурации»
/// проверяется на чистой машине, где токена нет.
///
/// Поэтому: анонимный <c>/health</c> отдаёт только пригодность к работе,
/// подробный состав компонентов доступен под токеном. Публичный домен
/// индексируется и сканируется (AR-1.2) — устройство системы наружу не
/// отдаётся.
/// </summary>
public static class HealthEndpoints
{
    public static IEndpointRouteBuilder MapHealthEndpoints(this IEndpointRouteBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        app.MapHealthChecks("/health", new HealthCheckOptions
        {
            ResponseWriter = WriteStatusOnly,
        })
        .AllowAnonymous()
        .WithName("health-liveness");

        app.MapHealthChecks("/api/v1/health", new HealthCheckOptions
        {
            ResponseWriter = WriteComponentDetails,
        })
        .RequireAuthorization()
        .WithName("health-components");

        return app;
    }

    /// <summary>
    /// Анонимный ответ: одно слово состояния. Ни состава компонентов,
    /// ни версий, ни имён хостов.
    /// </summary>
    private static Task WriteStatusOnly(HttpContext context, HealthReport report)
    {
        context.Response.ContentType = "application/json; charset=utf-8";

        return context.Response.WriteAsync(
            JsonSerializer.Serialize(new { status = ToWireValue(report.Status) }),
            context.RequestAborted);
    }

    /// <summary>
    /// Подробный ответ под токеном: раздельный статус БД, Home
    /// Assistant и провайдера LLM (NFR-OBS-3).
    /// </summary>
    private static Task WriteComponentDetails(HttpContext context, HealthReport report)
    {
        context.Response.ContentType = "application/json; charset=utf-8";

        var payload = new
        {
            status = ToWireValue(report.Status),
            duration_ms = (int)report.TotalDuration.TotalMilliseconds,
            components = report.Entries
                .SelectMany(entry => entry.Value.Data)
                .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal),
        };

        return context.Response.WriteAsync(
            JsonSerializer.Serialize(payload),
            context.RequestAborted);
    }

    private static string ToWireValue(HealthStatus status) => status switch
    {
        HealthStatus.Healthy => "healthy",
        HealthStatus.Degraded => "degraded",
        _ => "unhealthy",
    };
}
