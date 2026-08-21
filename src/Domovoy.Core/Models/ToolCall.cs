namespace Domovoy.Core.Models;

/// <summary>
/// Вызов инструмента, пришедший от модели. Аргументы — плоский набор
/// строк: разбор типов на стороне инструмента, который знает свою схему.
/// </summary>
public sealed record ToolCall
{
    /// <summary>Идентификатор вызова, сопоставляет вызов и результат.</summary>
    public required string Id { get; init; }

    public required string Name { get; init; }

    public required IReadOnlyDictionary<string, string> Arguments { get; init; }
}
