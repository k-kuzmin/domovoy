using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Options;

namespace Domovoy.Core.Auth;

/// <summary>
/// Привязка, проверка и отзыв устройств.
///
/// Открытые значения токена и кода существуют только здесь и в ответе
/// вызывающему — один раз; хранилище получает их SHA-256. Кэша поиска
/// токена нет: каждый запрос идёт в хранилище, поэтому отзыв действует со
/// следующего запроса. Исключения хранилища не перехватываются: решение,
/// что ответить клиенту, принимает транспорт.
/// </summary>
public sealed class DeviceAuthService
{
    /// <summary>Имя действия в аудите отзыва устройства.</summary>
    public const string RevokeDeviceAuditToolName = "revoke_device";

    /// <summary>Отметка last_seen обновляется не чаще этого интервала.</summary>
    private static readonly TimeSpan LastSeenResolution = TimeSpan.FromMinutes(1);

    private readonly IDeviceStore _store;
    private readonly IOptions<AuthOptions> _options;
    private readonly TimeProvider _timeProvider;

    public DeviceAuthService(IDeviceStore store, IOptions<AuthOptions> options, TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(timeProvider);

        _store = store;
        _options = options;
        _timeProvider = timeProvider;
    }

    /// <summary>Выпускает одноразовый код привязки со сроком из настроек.</summary>
    public async Task<PairingCodeIssued> IssuePairingCodeAsync(CancellationToken cancellationToken = default)
    {
        string code = DeviceSecrets.NewPairingCode();
        DateTimeOffset now = _timeProvider.GetUtcNow();
        DateTimeOffset expiresAt = now.AddMinutes(_options.Value.PairingCodeLifetimeMinutes);

        await _store.AddPairingCodeAsync(DeviceSecrets.Hash(code), now, expiresAt, cancellationToken)
            .ConfigureAwait(false);

        return new PairingCodeIssued(code, expiresAt);
    }

    /// <summary>
    /// Обменивает код привязки на токен устройства. <see langword="null"/> —
    /// код неверный, просроченный или уже погашен: причины не различаются,
    /// чтобы ответ не подсказывал, какой код существовал.
    /// </summary>
    public async Task<string?> RedeemPairingCodeAsync(
        string code,
        string? name,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return null;
        }

        string token = DeviceSecrets.NewToken();
        string? deviceName = string.IsNullOrWhiteSpace(name) ? null : name.Trim();

        Guid? deviceId = await _store.RedeemPairingCodeAsync(
                DeviceSecrets.Hash(DeviceSecrets.NormalizePairingCode(code)),
                DeviceSecrets.Hash(token),
                deviceName,
                _timeProvider.GetUtcNow(),
                cancellationToken)
            .ConfigureAwait(false);

        return deviceId is null ? null : token;
    }

    /// <summary>
    /// Ищет неотозванное устройство по предъявленному токену. Только поиск:
    /// last_seen не трогается, исключение хранилища пробрасывается.
    /// </summary>
    public async Task<ActiveDevice?> AuthenticateAsync(string token, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(token))
        {
            return null;
        }

        return await _store.FindActiveDeviceAsync(DeviceSecrets.Hash(token), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Обновляет last_seen, если прошлая отметка старше минуты или её нет.
    /// Исключение хранилища пробрасывается: сбой отметки не должен
    /// отказывать в запросе, и это решает вызывающий.
    /// </summary>
    public async Task TouchLastSeenIfStaleAsync(ActiveDevice device, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(device);

        DateTimeOffset now = _timeProvider.GetUtcNow();
        if (device.LastSeenAt is { } lastSeen && now - lastSeen < LastSeenResolution)
        {
            return;
        }

        await _store.TouchLastSeenAsync(device.Id, now, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Все устройства, включая отозванные, по времени привязки.</summary>
    public Task<IReadOnlyList<DeviceInfo>> ListDevicesAsync(CancellationToken cancellationToken = default) =>
        _store.ListDevicesAsync(cancellationToken);

    /// <summary>
    /// Отзывает устройство и передаёт хранилищу запись аудита — отзыв и
    /// аудит атомарны. <see langword="false"/> — устройства нет или оно уже
    /// отозвано.
    /// </summary>
    public Task<bool> RevokeDeviceAsync(Guid id, string requestId, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(requestId);

        DateTimeOffset now = _timeProvider.GetUtcNow();
        var audit = new AuditEntry
        {
            OccurredAt = now,
            RequestId = requestId,
            Source = AgentRequestSource.Admin,
            OriginalPhrase = "",
            ToolName = RevokeDeviceAuditToolName,
            Arguments = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["device_id"] = id.ToString(),
            },
            Success = true,
        };

        return _store.RevokeDeviceAsync(id, audit, now, cancellationToken);
    }
}
