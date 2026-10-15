namespace Domovoy.Core.Models;

/// <summary>
/// Привязанное устройство в списке администратора. Значения токена здесь
/// нет: хранилище знает только его хеш, а наружу хеш не отдаётся.
/// </summary>
public sealed record DeviceInfo(
    Guid Id,
    string? Name,
    DateTimeOffset CreatedAt,
    DateTimeOffset? LastSeenAt,
    DateTimeOffset? RevokedAt);

/// <summary>
/// Устройство, найденное по предъявленному токену и не отозванное.
/// <see cref="LastSeenAt"/> нужен, чтобы обновлять отметку не чаще раза
/// в минуту, а не на каждом запросе.
/// </summary>
public sealed record ActiveDevice(Guid Id, DateTimeOffset? LastSeenAt);
