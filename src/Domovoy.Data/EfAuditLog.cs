using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Domovoy.Data.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;

namespace Domovoy.Data;

/// <summary>
/// Аудит-лог изменяющих действий (FR-CORE-6), ретенция не менее
/// 90 дней (NFR-SEC-5). Строка таблицы <c>audit_entries</c> собирается
/// тем же маппингом <see cref="AuditRecord.From"/>, что и аудит отзыва
/// устройства.
/// </summary>
internal sealed class EfAuditLog : IAuditLog
{
    private readonly DomovoyDbContext _db;

    public EfAuditLog(DomovoyDbContext db) => _db = db;

    public async Task WriteAsync(AuditEntry entry, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(entry);

        EntityEntry record = _db.Add(AuditRecord.From(entry));

        try
        {
            await _db.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Неудачная вставка не должна повториться следующим
            // SaveChanges того же контекста.
            record.State = EntityState.Detached;
            throw;
        }
    }
}
