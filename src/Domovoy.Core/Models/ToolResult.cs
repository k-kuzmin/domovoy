namespace Domovoy.Core.Models;

/// <summary>Результат вызова инструмента.</summary>
public sealed record ToolResult
{
    /// <summary>
    /// Значение <see cref="ToolCallId"/> для результата, построенного не
    /// из вызова инструмента моделью: прямой вызов слоя Home Assistant и
    /// быстрый путь. Инструмент, получивший такой результат, ставит id
    /// своего вызова: <c>result with { ToolCallId = call.Id }</c>.
    /// </summary>
    public const string DirectCallId = "direct";

    public required string ToolCallId { get; init; }

    public required bool Success { get; init; }

    /// <summary>
    /// Содержимое результата, передаётся модели как данные, а не как
    /// инструкции (NFR-SEC-6). Результат не может изменить системный
    /// промпт или расширить allow-list.
    /// </summary>
    public string? Payload { get; init; }

    /// <summary>Причина отказа. Заполняется, когда <see cref="Success"/> ложно.</summary>
    public string? Error { get; init; }

    /// <summary>
    /// Машиночитаемый код отказа из <see cref="HaErrorCodes"/>; те же строки
    /// идут в <see cref="ApiError.Code"/>. <c>null</c> — успех или отказ без
    /// кода.
    /// </summary>
    public string? ErrorCode { get; init; }

    /// <summary>
    /// Действие требует подтверждения: инструмент ничего не сделал и
    /// вернул описание для диалога подтверждения.
    /// </summary>
    public bool RequiresConfirmation { get; init; }
}
