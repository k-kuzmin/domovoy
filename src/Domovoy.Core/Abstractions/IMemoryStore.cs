using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Долговременная память: факты, сохранённые через инструмент
/// <c>remember</c> (FR-MEM-3).
/// </summary>
public interface IMemoryStore
{
    Task<MemoryFact?> GetAsync(string key, CancellationToken cancellationToken);

    /// <summary>Записи, релевантные запросу. Подмешиваются в контекст.</summary>
    Task<IReadOnlyList<MemoryFact>> FindRelevantAsync(
        string query,
        int limit,
        CancellationToken cancellationToken);

    Task SetAsync(string key, string value, CancellationToken cancellationToken);
}
