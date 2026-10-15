using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Хранилище привязанных устройств и кодов привязки.
///
/// Порт оперирует только хешами: открытые значения токена и кода до
/// хранилища не доходят, поэтому утечка базы не даёт ни действующего
/// токена, ни кода.
/// </summary>
public interface IDeviceStore
{
    /// <summary>Сохраняет хеш выпущенного кода привязки.</summary>
    Task AddPairingCodeAsync(
        byte[] codeHash,
        DateTimeOffset createdAt,
        DateTimeOffset expiresAt,
        CancellationToken ct);

    /// <summary>
    /// Атомарно гасит код и заводит устройство с хешем токена. Возвращает
    /// id нового устройства; <see langword="null"/> — код неверный,
    /// просроченный на момент <paramref name="now"/> или уже погашен, и
    /// устройство тогда не заводится.
    /// </summary>
    Task<Guid?> RedeemPairingCodeAsync(
        byte[] codeHash,
        byte[] tokenHash,
        string? deviceName,
        DateTimeOffset now,
        CancellationToken ct);

    /// <summary>
    /// Ищет неотозванное устройство (<c>revoked_at IS NULL</c>) по хешу
    /// токена.
    /// </summary>
    Task<ActiveDevice?> FindActiveDeviceAsync(byte[] tokenHash, CancellationToken ct);

    /// <summary>Записывает время последнего обращения устройства.</summary>
    Task TouchLastSeenAsync(Guid id, DateTimeOffset now, CancellationToken ct);

    /// <summary>Все устройства, включая отозванные, по времени привязки.</summary>
    Task<IReadOnlyList<DeviceInfo>> ListDevicesAsync(CancellationToken ct);

    /// <summary>
    /// Атомарно отмечает устройство отозванным и пишет
    /// <paramref name="audit"/>: сбой записи аудита откатывает отзыв.
    /// <see langword="false"/> — устройства нет или оно уже отозвано, и
    /// аудит тогда не пишется.
    /// </summary>
    Task<bool> RevokeDeviceAsync(Guid id, AuditEntry audit, DateTimeOffset now, CancellationToken ct);
}
