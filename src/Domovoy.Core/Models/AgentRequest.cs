namespace Domovoy.Core.Models;

/// <summary>Источник запроса. Пишется в аудит-лог (FR-CORE-6).</summary>
public enum AgentRequestSource
{
    /// <summary>Текстовый запрос через <c>/chat</c>.</summary>
    Text,

    /// <summary>Голосовой запрос через <c>/voice</c>, распознанный STT.</summary>
    Voice,

    /// <summary>Быстрое действие из интерфейса, минуя LLM.</summary>
    Ui,
}

/// <summary>
/// Единая точка входа в оркестратор. Аудио уже прогнано через STT:
/// дальше путь один и тот же (FR-CORE-1).
/// </summary>
public sealed record AgentRequest
{
    /// <summary>Корреляция логов через весь путь (NFR-OBS-1).</summary>
    public required string RequestId { get; init; }

    /// <summary>Идентификатор устройства, прошедшего аутентификацию.</summary>
    public required string DeviceId { get; init; }

    /// <summary>Текст запроса. Для голоса — результат распознавания.</summary>
    public required string Text { get; init; }

    public required AgentRequestSource Source { get; init; }

    /// <summary>
    /// Диалог, к которому относится запрос. История общая между
    /// устройствами одного пользователя (FR-MEM-1).
    /// </summary>
    public string? ConversationId { get; init; }
}
