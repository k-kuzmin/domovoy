namespace Domovoy.Core.Models;

/// <summary>
/// Запись аудит-лога изменяющего действия (FR-CORE-6). Ретенция не
/// менее 90 дней (NFR-SEC-5).
/// </summary>
public sealed record AuditEntry
{
    public required DateTimeOffset OccurredAt { get; init; }

    public required string RequestId { get; init; }

    public required AgentRequestSource Source { get; init; }

    /// <summary>Исходная фраза пользователя.</summary>
    public required string OriginalPhrase { get; init; }

    public required string ToolName { get; init; }

    /// <summary>
    /// Аргументы вызова. Секретов здесь быть не может: инструменты
    /// принимают идентификаторы сущностей и значения, не ключи.
    /// </summary>
    public required IReadOnlyDictionary<string, string> Arguments { get; init; }

    public required bool Success { get; init; }

    public string? Error { get; init; }
}
