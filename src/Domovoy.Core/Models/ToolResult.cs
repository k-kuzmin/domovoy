namespace Domovoy.Core.Models;

/// <summary>Результат вызова инструмента.</summary>
public sealed record ToolResult
{
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
    /// Действие требует подтверждения: инструмент ничего не сделал и
    /// вернул описание для диалога подтверждения.
    /// </summary>
    public bool RequiresConfirmation { get; init; }
}
