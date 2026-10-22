using Domovoy.Core.Models;

namespace Domovoy.Api.Endpoints;

/// <summary>
/// Единственный писатель единого формата ошибок
/// <c>{ error: { code, message } }</c> (раздел 5 ТЗ). Им пользуются
/// эндпоинты, обработчики аутентификации и лимитер: формат отказа не должен
/// зависеть от того, на каком слое запрос остановлен.
///
/// Сообщение не содержит ни текста исключения, ни предъявленных значений:
/// публичный домен индексируется и сканируется (AR-1.2).
/// </summary>
internal static class ApiErrorResults
{
    public const string Unauthorized = "unauthorized";
    public const string Forbidden = "forbidden";
    public const string RateLimited = "rate_limited";
    public const string InvalidPairingCode = "invalid_pairing_code";
    public const string InvalidRequest = "invalid_request";
    public const string DeviceNotFound = "device_not_found";
    public const string AuthUnavailable = "auth_unavailable";
    public const string NotImplemented = "not_implemented";

    /// <summary>
    /// Отказ, которому нет строки в таблице статусов: например, код слоя
    /// Home Assistant, о котором эндпоинт ещё не знает.
    /// </summary>
    public const string InternalError = "internal_error";

    /// <summary>Сообщение ответа 503 при сбое хранилища устройств.</summary>
    public const string AuthUnavailableMessage =
        "Проверка устройства временно недоступна. Повторите запрос позже.";

    /// <summary>Ответ эндпоинта в едином формате.</summary>
    public static IResult Result(int status, string code, string message) =>
        Results.Json(
            new { error = new ApiError { Code = code, Message = message } },
            statusCode: status);

    /// <summary>
    /// Запись того же ответа напрямую в <see cref="HttpContext.Response"/> —
    /// для обработчиков аутентификации и лимитера, у которых нет
    /// <see cref="IResult"/>.
    /// </summary>
    public static Task Write(HttpContext context, int status, string code, string message)
    {
        ArgumentNullException.ThrowIfNull(context);

        return Result(status, code, message).ExecuteAsync(context);
    }
}
