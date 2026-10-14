namespace Domovoy.Core.Models;

/// <summary>Текущее состояние сущности.</summary>
public sealed record HaEntityState
{
    public required string EntityId { get; init; }

    public required string State { get; init; }

    /// <summary>
    /// Атрибуты сущности. Содержимое — данные, а не инструкции для LLM
    /// (NFR-SEC-6): текст внутри атрибутов не может изменить системный
    /// промпт или расширить allow-list.
    /// </summary>
    public required IReadOnlyDictionary<string, string> Attributes { get; init; }

    public required DateTimeOffset LastChanged { get; init; }

    /// <summary>
    /// <c>last_updated</c> Home Assistant: меняется и при смене одних
    /// атрибутов. По нему упорядочиваются события одной сущности.
    /// </summary>
    public required DateTimeOffset LastUpdated { get; init; }
}
