using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Data;

/// <summary>
/// Долговременная память (FR-MEM-3).
///
/// Каркас: реализация появляется на этапе 6. Открытый вопрос —
/// способ поиска релевантных записей: FR-CORE-4 требует релевантности
/// по эмбеддингу, но провайдер эмбеддингов в ТЗ не задан.
/// </summary>
internal sealed class EfMemoryStore : IMemoryStore
{
    private readonly DomovoyDbContext _db;

    public EfMemoryStore(DomovoyDbContext db) => _db = db;

    public Task<MemoryFact?> GetAsync(string key, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 6: чтение факта долговременной памяти.");

    public Task<IReadOnlyList<MemoryFact>> FindRelevantAsync(
        string query,
        int limit,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 6: подбор релевантных фактов.");

    public Task SetAsync(string key, string value, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 6: запись факта через инструмент remember.");
}
