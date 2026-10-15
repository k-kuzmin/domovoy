using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Domovoy.Data.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Storage;

namespace Domovoy.Data;

/// <summary>
/// Хранилище устройств и кодов привязки в PostgreSQL.
///
/// Атомарность — условными UPDATE в транзакции, а не чтением с
/// последующей записью: два одновременных обмена одного кода упираются в
/// блокировку строки, и второй видит уже погашенный код.
/// </summary>
internal sealed class EfDeviceStore : IDeviceStore
{
    private readonly DomovoyDbContext _db;

    public EfDeviceStore(DomovoyDbContext db) => _db = db;

    public async Task AddPairingCodeAsync(
        byte[] codeHash,
        DateTimeOffset createdAt,
        DateTimeOffset expiresAt,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(codeHash);

        await InsertAsync(
            new PairingCodeRecord
            {
                Id = Guid.NewGuid(),
                CodeHash = codeHash,
                CreatedAt = createdAt,
                ExpiresAt = expiresAt,
            },
            ct).ConfigureAwait(false);
    }

    public async Task<Guid?> RedeemPairingCodeAsync(
        byte[] codeHash,
        byte[] tokenHash,
        string? deviceName,
        DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(codeHash);
        ArgumentNullException.ThrowIfNull(tokenHash);

        Guid deviceId = Guid.NewGuid();

        IDbContextTransaction transaction =
            await _db.Database.BeginTransactionAsync(ct).ConfigureAwait(false);

        await using (transaction.ConfigureAwait(false))
        {
            int redeemed = await _db.Set<PairingCodeRecord>()
                .Where(c => c.CodeHash == codeHash && c.UsedAt == null && c.ExpiresAt > now)
                .ExecuteUpdateAsync(
                    s => s.SetProperty(c => c.UsedAt, now).SetProperty(c => c.DeviceId, deviceId),
                    ct)
                .ConfigureAwait(false);

            if (redeemed != 1)
            {
                await transaction.RollbackAsync(ct).ConfigureAwait(false);
                return null;
            }

            await InsertAsync(
                new DeviceRecord
                {
                    Id = deviceId,
                    Name = deviceName,
                    TokenHash = tokenHash,
                    CreatedAt = now,
                },
                ct).ConfigureAwait(false);
            await transaction.CommitAsync(ct).ConfigureAwait(false);
        }

        return deviceId;
    }

    public async Task<ActiveDevice?> FindActiveDeviceAsync(byte[] tokenHash, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(tokenHash);

        return await _db.Set<DeviceRecord>()
            .AsNoTracking()
            .Where(d => d.TokenHash == tokenHash && d.RevokedAt == null)
            .Select(d => new ActiveDevice(d.Id, d.LastSeenAt))
            .SingleOrDefaultAsync(ct)
            .ConfigureAwait(false);
    }

    public async Task TouchLastSeenAsync(Guid id, DateTimeOffset now, CancellationToken ct) =>
        await _db.Set<DeviceRecord>()
            .Where(d => d.Id == id)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.LastSeenAt, now), ct)
            .ConfigureAwait(false);

    public async Task<IReadOnlyList<DeviceInfo>> ListDevicesAsync(CancellationToken ct) =>
        await _db.Set<DeviceRecord>()
            .AsNoTracking()
            .OrderBy(d => d.CreatedAt)
            .ThenBy(d => d.Id)
            .Select(d => new DeviceInfo(d.Id, d.Name, d.CreatedAt, d.LastSeenAt, d.RevokedAt))
            .ToListAsync(ct)
            .ConfigureAwait(false);

    public async Task<bool> RevokeDeviceAsync(
        Guid id,
        AuditEntry audit,
        DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(audit);

        IDbContextTransaction transaction =
            await _db.Database.BeginTransactionAsync(ct).ConfigureAwait(false);

        await using (transaction.ConfigureAwait(false))
        {
            int revoked = await _db.Set<DeviceRecord>()
                .Where(d => d.Id == id && d.RevokedAt == null)
                .ExecuteUpdateAsync(s => s.SetProperty(d => d.RevokedAt, now), ct)
                .ConfigureAwait(false);

            if (revoked != 1)
            {
                await transaction.RollbackAsync(ct).ConfigureAwait(false);
                return false;
            }

            // Сбой записи аудита до Commit оставляет транзакцию
            // незафиксированной: освобождение откатывает и отметку отзыва.
            await InsertAsync(AuditRecord.From(audit), ct).ConfigureAwait(false);
            await transaction.CommitAsync(ct).ConfigureAwait(false);
        }

        return true;
    }

    /// <summary>
    /// Вставляет строку; при сбое снимает её с отслеживания, чтобы
    /// следующий SaveChanges того же контекста не повторил неудачную
    /// вставку.
    /// </summary>
    private async Task InsertAsync(object record, CancellationToken ct)
    {
        EntityEntry entry = _db.Add(record);

        try
        {
            await _db.SaveChangesAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            entry.State = EntityState.Detached;
            throw;
        }
    }
}
