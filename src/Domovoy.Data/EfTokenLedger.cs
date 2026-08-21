using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Data;

/// <summary>
/// Учёт расхода токенов (NFR-COST-1) и месячный потолок (NFR-COST-2).
/// Каркас: реализация появляется на этапе 2.
/// </summary>
internal sealed class EfTokenLedger : ITokenLedger
{
    private readonly DomovoyDbContext _db;

    public EfTokenLedger(DomovoyDbContext db) => _db = db;

    public Task RecordAsync(
        string requestId,
        string provider,
        TokenUsage usage,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: запись расхода токенов по запросу.");

    public Task<int> GetMonthlyTotalAsync(CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: расход за текущий месяц.");

    public Task<bool> IsBudgetExhaustedAsync(CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: проверка месячного потолка.");
}
