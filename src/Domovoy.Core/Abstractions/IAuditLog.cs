using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Аудит-лог изменяющих действий (FR-CORE-6). Ретенция не менее
/// 90 дней (NFR-SEC-5).
/// </summary>
public interface IAuditLog
{
    Task WriteAsync(AuditEntry entry, CancellationToken cancellationToken);
}
