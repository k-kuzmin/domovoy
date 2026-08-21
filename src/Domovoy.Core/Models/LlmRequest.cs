namespace Domovoy.Core.Models;

/// <summary>Запрос к провайдеру LLM.</summary>
public sealed record LlmRequest
{
    public required IReadOnlyList<LlmMessage> Messages { get; init; }

    /// <summary>
    /// Схемы доступных инструментов. Плоские, максимум 2 уровня:
    /// GigaChat хуже работает с вложенными схемами и не поддерживает
    /// параллельный вызов нескольких функций (раздел 3 ТЗ).
    /// </summary>
    public required IReadOnlyList<AgentToolDescriptor> Tools { get; init; }

    public double? Temperature { get; init; }

    public int? MaxTokens { get; init; }
}
