namespace Domovoy.Core.Models;

/// <summary>
/// Фрагмент потокового ответа модели.
///
/// Провайдер, не поддерживающий стриминг, эмулируется адаптером: весь
/// ответ отдаётся одним фрагментом. Вызывающий код не должен зависеть
/// от того, реальный это поток или эмуляция (FR-CORE-8).
/// </summary>
public sealed record LlmStreamChunk
{
    /// <summary>Частичный текст ответа. <c>null</c>, если фрагмент несёт вызов инструмента.</summary>
    public string? TextDelta { get; init; }

    /// <summary>Вызов инструмента, если модель его запросила.</summary>
    public ToolCall? ToolCall { get; init; }

    /// <summary>Расход токенов. Заполняется в последнем фрагменте.</summary>
    public TokenUsage? Usage { get; init; }

    /// <summary>Последний фрагмент потока.</summary>
    public bool IsFinal { get; init; }
}
