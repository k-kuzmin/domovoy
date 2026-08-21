using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Data;

/// <summary>
/// Аудит-лог изменяющих действий (FR-CORE-6), ретенция не менее
/// 90 дней (NFR-SEC-5).
/// Каркас: реализация появляется на этапе 1.
/// </summary>
internal sealed class EfAuditLog : IAuditLog
{
    private readonly DomovoyDbContext _db;

    public EfAuditLog(DomovoyDbContext db) => _db = db;

    public Task WriteAsync(AuditEntry entry, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 1: запись в аудит-лог.");
}
