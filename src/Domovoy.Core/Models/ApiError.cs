namespace Domovoy.Core.Models;

/// <summary>
/// Единый формат ошибок API (раздел 5 ТЗ):
/// <c>{ "error": { "code", "message", "details" } }</c>.
/// </summary>
public sealed record ApiError
{
    public required string Code { get; init; }

    /// <summary>
    /// Сообщение для пользователя. Не содержит внутренних адресов,
    /// имён хостов и текстов исключений: публичный домен индексируется
    /// и сканируется (AR-1.2).
    /// </summary>
    public required string Message { get; init; }

    public IReadOnlyDictionary<string, string>? Details { get; init; }
}
