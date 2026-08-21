namespace Domovoy.Core.Models;

/// <summary>
/// Факт долговременной памяти (FR-MEM-3). Хранение key-value,
/// релевантные записи подмешиваются в контекст.
/// </summary>
public sealed record MemoryFact
{
    public required string Key { get; init; }

    public required string Value { get; init; }

    public required DateTimeOffset UpdatedAt { get; init; }
}
