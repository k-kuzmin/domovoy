using System.Text.Json;
using Domovoy.Api.Security;
using Domovoy.Core.Auth;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Контракт API (раздел 5 ТЗ). Эндпоинты, чей этап не наступил, объявлены
/// и отвечают 501: контракт зафиксирован и виден клиенту, реализация
/// приходит по этапам.
///
/// Группа требует аутентификации целиком. Исключение делается явно и
/// только с записью решения — см. .claude/CLAUDE.md.
/// </summary>
public static class ApiV1Endpoints
{
    /// <summary>Предел длины имени устройства — колонка devices.name varchar(64).</summary>
    private const int MaxDeviceNameLength = 64;

    public static IEndpointRouteBuilder MapApiV1Endpoints(this IEndpointRouteBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        RouteGroupBuilder api = app.MapGroup("/api/v1").RequireAuthorization();

        api.MapPost("/auth/device", RedeemPairingCodeAsync)
            .WithName("auth-device")
            // Обмен кода привязки на токен по определению выполняется
            // без токена. Анонимность здесь — часть назначения
            // эндпоинта, а не упущение; защита строится на одноразовом
            // коде привязки и ограничении частоты (запись 0025).
            .AllowAnonymous()
            .RequireRateLimiting(DeviceTokenDefaults.PairingRateLimitPolicy);

        api.MapPost("/chat", () => NotImplemented("Этап 1: текстовый запрос, поток SSE."))
            .WithName("chat");

        api.MapPost("/voice", () => NotImplemented("Этап 4: multipart с аудио, событие recognized первым."))
            .WithName("voice");

        api.MapPost("/confirm", () => NotImplemented("Этап 6: подтверждение чувствительного действия."))
            .WithName("confirm");

        api.MapGet("/state", HomeEndpoints.GetStateAsync)
            .WithName("state");

        api.MapPost("/action", HomeEndpoints.PostActionAsync)
            .WithName("action");

        api.MapGet("/notifications", () => NotImplemented("Этап 3: лента уведомлений."))
            .WithName("notifications");

        return app;
    }

    /// <summary>
    /// Обмен кода привязки на токен устройства. Тело проверяется до
    /// обращения к хранилищу: отклонённый запрос код не гасит. Неверный,
    /// просроченный и погашенный код дают одинаковый ответ — он не
    /// подсказывает, какой код существовал. В ответе только токен
    /// (запись 0025), и он не кэшируется.
    /// </summary>
    private static async Task<IResult> RedeemPairingCodeAsync(
        HttpContext context,
        DeviceAuthService deviceAuth,
        ILoggerFactory loggerFactory)
    {
        PairingRequest? request = await ReadPairingRequestAsync(context);

        if (request is null || string.IsNullOrWhiteSpace(request.Code))
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidRequest,
                "Тело запроса — JSON с обязательным полем code.");
        }

        if (request.Name is { Length: > MaxDeviceNameLength })
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidRequest,
                $"Имя устройства длиннее {MaxDeviceNameLength} символов.");
        }

        // PostgreSQL не принимает U+0000 в text: без этой проверки такое имя
        // доходило бы до базы и возвращалось 503 вместо ошибки запроса.
        if (request.Name is not null && request.Name.Any(char.IsControl))
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidRequest,
                "Имя устройства содержит управляющие символы.");
        }

        string? token;
        try
        {
            token = await deviceAuth.RedeemPairingCodeAsync(request.Code, request.Name, context.RequestAborted);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            loggerFactory.CreateLogger(typeof(ApiV1Endpoints).FullName!)
                .LogWarning(exception, "Хранилище устройств недоступно: код привязки не обменян.");
            return ApiErrorResults.Result(
                StatusCodes.Status503ServiceUnavailable,
                ApiErrorResults.AuthUnavailable,
                ApiErrorResults.AuthUnavailableMessage);
        }

        if (token is null)
        {
            return ApiErrorResults.Result(
                StatusCodes.Status400BadRequest,
                ApiErrorResults.InvalidPairingCode,
                "Код привязки неверен, просрочен или уже использован.");
        }

        context.Response.Headers.CacheControl = "no-store";
        return Results.Json(new PairingResponse(token));
    }

    /// <summary>
    /// Тело читается вручную, а не привязкой параметра: при неверном JSON
    /// привязка ответила бы своим форматом, а не единым.
    /// </summary>
    private static async Task<PairingRequest?> ReadPairingRequestAsync(HttpContext context)
    {
        if (!context.Request.HasJsonContentType())
        {
            return null;
        }

        try
        {
            return await context.Request.ReadFromJsonAsync<PairingRequest>(context.RequestAborted);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// Ответ в едином формате ошибок: <c>{ error: { code, message } }</c>.
    /// Формат один с первого дня — клиент, написанный под каркас,
    /// продолжит работать после реализации.
    /// </summary>
    private static IResult NotImplemented(string message) =>
        ApiErrorResults.Result(StatusCodes.Status501NotImplemented, ApiErrorResults.NotImplemented, message);

    private sealed record PairingRequest(string? Code, string? Name);

    private sealed record PairingResponse(string Token);
}
