namespace Domovoy.Data.Entities;

/// <summary>
/// Привязанное устройство (таблица <c>devices</c>). Открытого значения
/// токена здесь нет: хранится только SHA-256 от него.
/// </summary>
internal sealed class DeviceRecord
{
    /// <summary>Ограничение длины имени устройства — колонка <c>varchar(64)</c>.</summary>
    public const int NameMaxLength = 64;

    public Guid Id { get; set; }

    public string? Name { get; set; }

    public byte[] TokenHash { get; set; } = [];

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? LastSeenAt { get; set; }

    public DateTimeOffset? RevokedAt { get; set; }
}
