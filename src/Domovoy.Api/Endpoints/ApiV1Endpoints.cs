using Domovoy.Core.Models;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Контракт API (раздел 5 ТЗ). На этапе каркаса каждый эндпоинт
/// объявлен и отвечает 501: контракт зафиксирован и виден клиенту,
/// реализация приходит по этапам.
///
/// Группа требует аутентификации целиком. Исключение делается явно и
/// только с записью решения — см. .claude/CLAUDE.md.
/// </summary>
public static class ApiV1Endpoints
{
    private const string NotImplementedCode = "not_implemented";

    public static IEndpointRouteBuilder MapApiV1Endpoints(this IEndpointRouteBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        RouteGroupBuilder api = app.MapGroup("/api/v1").RequireAuthorization();

        api.MapPost("/auth/device", () => NotImplemented("Этап 5: обмен кода привязки на токен устройства."))
            .WithName("auth-device")
            // Обмен кода привязки на токен по определению выполняется
            // без токена. Анонимность здесь — часть назначения
            // эндпоинта, а не упущение; защита строится на одноразовом
            // коде привязки и ограничении частоты.
            .AllowAnonymous();

        api.MapPost("/chat", () => NotImplemented("Этап 1: текстовый запрос, поток SSE."))
            .WithName("chat");

        api.MapPost("/voice", () => NotImplemented("Этап 4: multipart с аудио, событие recognized первым."))
            .WithName("voice");

        api.MapPost("/confirm", () => NotImplemented("Этап 6: подтверждение чувствительного действия."))
            .WithName("confirm");

        api.MapGet("/state", () => NotImplemented("Этап 1: срез состояния дома для экрана «Дом»."))
            .WithName("state");

        api.MapPost("/action", () => NotImplemented("Этап 1: быстрое действие из интерфейса, минуя LLM."))
            .WithName("action");

        api.MapGet("/notifications", () => NotImplemented("Этап 3: лента уведомлений."))
            .WithName("notifications");

        return app;
    }

    /// <summary>
    /// Ответ в едином формате ошибок: <c>{ error: { code, message } }</c>.
    /// Формат один с первого дня — клиент, написанный под каркас,
    /// продолжит работать после реализации.
    /// </summary>
    private static IResult NotImplemented(string message) =>
        Results.Json(
            new { error = new ApiError { Code = NotImplementedCode, Message = message } },
            statusCode: StatusCodes.Status501NotImplemented);
}
