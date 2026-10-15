namespace Domovoy.Data.Entities;

/// <summary>
/// Выпущенный код привязки (таблица <c>pairing_codes</c>). Открытого
/// значения кода здесь нет: хранится только SHA-256 от него.
/// </summary>
internal sealed class PairingCodeRecord
{
    public Guid Id { get; set; }

    public byte[] CodeHash { get; set; } = [];

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset ExpiresAt { get; set; }

    /// <summary>Момент погашения; <see langword="null"/> — код ещё не погашен.</summary>
    public DateTimeOffset? UsedAt { get; set; }

    /// <summary>Устройство, заведённое по этому коду.</summary>
    public Guid? DeviceId { get; set; }
}
