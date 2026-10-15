using System.Text;
using Domovoy.Core.Auth;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using FluentAssertions;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Привязка, проверка и отзыв устройств на уровне сервиса ядра (#12, #13):
/// одноразовость и срок кода, хранение только хешей, аудит отзыва и
/// частота обновления last_seen. Хранилище — <see cref="InMemoryDeviceStore"/>,
/// время — <see cref="ManualTimeProvider"/>.
/// </summary>
public sealed class DeviceAuthServiceTests
{
    private const int LifetimeMinutes = 10;

    private readonly InMemoryDeviceStore _store = new();
    private readonly ManualTimeProvider _time = new();
    private readonly DeviceAuthService _service;

    public DeviceAuthServiceTests()
    {
        _service = new DeviceAuthService(
            _store,
            Options.Create(new AuthOptions { PairingCodeLifetimeMinutes = LifetimeMinutes }),
            _time);
    }

    [Fact(DisplayName = "Погашенный код второй раз токена не выдаёт и устройства не заводит")]
    public async Task RedeemedPairingCodeCannotBeRedeemedAgain()
    {
        PairingCodeIssued issued = await _service.IssuePairingCodeAsync();

        string? first = await _service.RedeemPairingCodeAsync(issued.Code, "Телефон");
        string? second = await _service.RedeemPairingCodeAsync(issued.Code, "Чужой телефон");

        first.Should().NotBeNullOrEmpty();
        second.Should().BeNull();
        IReadOnlyList<DeviceInfo> devices = await _service.ListDevicesAsync();
        devices.Should().ContainSingle().Which.Name.Should().Be("Телефон");
    }

    [Fact(DisplayName = "Просроченный код токена не выдаёт, за секунду до истечения — выдаёт")]
    public async Task ExpiredPairingCodeIsRejected()
    {
        PairingCodeIssued expiring = await _service.IssuePairingCodeAsync();
        PairingCodeIssued stillValid = await _service.IssuePairingCodeAsync();

        _time.Advance(TimeSpan.FromMinutes(LifetimeMinutes) - TimeSpan.FromSeconds(1));
        string? beforeExpiry = await _service.RedeemPairingCodeAsync(stillValid.Code, null);

        _time.Advance(TimeSpan.FromSeconds(2));
        string? afterExpiry = await _service.RedeemPairingCodeAsync(expiring.Code, null);

        expiring.ExpiresAt.Should().Be(stillValid.ExpiresAt);
        beforeExpiry.Should().NotBeNullOrEmpty();
        afterExpiry.Should().BeNull();
        (await _service.ListDevicesAsync()).Should().ContainSingle();
    }

    [Fact(DisplayName = "Хранилище получает только хеши токена и кода, не открытые значения")]
    public async Task StoreReceivesOnlyHashesOfTokenAndCode()
    {
        PairingCodeIssued issued = await _service.IssuePairingCodeAsync();
        string? token = await _service.RedeemPairingCodeAsync(issued.Code, null);

        token.Should().NotBeNull();
        // Байты сравниваются шестнадцатеричной строкой: так FluentAssertions
        // сравнивает значения, а не ссылки на массивы.
        List<string> stored = _store.StoredHashes.Select(Convert.ToHexString).ToList();

        stored.Should().NotContain(Convert.ToHexString(Encoding.UTF8.GetBytes(token!)));
        stored.Should().NotContain(Convert.ToHexString(Encoding.UTF8.GetBytes(issued.Code)));
        stored.Should().Contain(Convert.ToHexString(DeviceSecrets.Hash(token!)));
        stored.Should().Contain(Convert.ToHexString(DeviceSecrets.Hash(issued.Code)));
    }

    [Fact(DisplayName = "Отзыв пишет одну запись аудита без токена; отзыв неизвестного — ни одной")]
    public async Task RevocationWritesAuditEntryWithoutToken()
    {
        PairingCodeIssued issued = await _service.IssuePairingCodeAsync();
        string token = (await _service.RedeemPairingCodeAsync(issued.Code, "Телефон"))!;
        Guid deviceId = (await _service.ListDevicesAsync()).Single().Id;

        bool revoked = await _service.RevokeDeviceAsync(deviceId, "req-revoke");
        bool unknown = await _service.RevokeDeviceAsync(Guid.NewGuid(), "req-unknown");

        revoked.Should().BeTrue();
        unknown.Should().BeFalse();
        AuditEntry audit = _store.AuditEntries.Should().ContainSingle().Subject;
        audit.Source.Should().Be(AgentRequestSource.Admin);
        audit.ToolName.Should().Be("revoke_device");
        audit.RequestId.Should().Be("req-revoke");
        audit.Success.Should().BeTrue();
        audit.Arguments.Should().ContainKey("device_id").WhoseValue.Should().Be(deviceId.ToString());

        string[] fields =
        [
            audit.RequestId,
            audit.OriginalPhrase,
            audit.ToolName,
            audit.Error ?? "",
            .. audit.Arguments.Keys,
            .. audit.Arguments.Values,
        ];
        fields.Should().NotContain(field => field.Contains(token, StringComparison.Ordinal));
        (await _service.AuthenticateAsync(token)).Should().BeNull();
    }

    [Fact(DisplayName = "last_seen обновляется не чаще раза в минуту")]
    public async Task LastSeenIsTouchedAtMostOncePerMinute()
    {
        PairingCodeIssued issued = await _service.IssuePairingCodeAsync();
        string token = (await _service.RedeemPairingCodeAsync(issued.Code, null))!;
        DateTimeOffset firstTouch = _time.GetUtcNow();

        await TouchAsync(token);
        (await LastSeenAsync()).Should().Be(firstTouch);

        _time.Advance(TimeSpan.FromSeconds(59));
        await TouchAsync(token);
        (await LastSeenAsync()).Should().Be(firstTouch);

        _time.Advance(TimeSpan.FromSeconds(1));
        DateTimeOffset secondTouch = _time.GetUtcNow();
        await TouchAsync(token);
        (await LastSeenAsync()).Should().Be(secondTouch);
    }

    private async Task TouchAsync(string token)
    {
        ActiveDevice? device = await _service.AuthenticateAsync(token);
        device.Should().NotBeNull();
        await _service.TouchLastSeenIfStaleAsync(device!);
    }

    private async Task<DateTimeOffset?> LastSeenAsync() =>
        (await _service.ListDevicesAsync()).Single().LastSeenAt;
}
