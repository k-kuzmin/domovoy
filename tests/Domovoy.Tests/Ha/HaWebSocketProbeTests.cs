using Domovoy.Core.Models;
using Domovoy.Ha.WebSocket;
using FluentAssertions;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Проба <c>ha_websocket</c> для <c>/api/v1/health</c> (NFR-OBS-3):
/// отображение статуса соединения в состояние компонента по записи 0010.
/// </summary>
public sealed class HaWebSocketProbeTests
{
    [Theory(DisplayName = "Статус соединения отображается в состояние пробы")]
    [InlineData(nameof(HaConnectionStatus.Connected), ComponentState.Ok)]
    [InlineData(nameof(HaConnectionStatus.NotConfigured), ComponentState.NotConfigured)]
    [InlineData(nameof(HaConnectionStatus.Connecting), ComponentState.Unreachable)]
    [InlineData(nameof(HaConnectionStatus.Reconnecting), ComponentState.Unreachable)]
    [InlineData(nameof(HaConnectionStatus.AuthRejected), ComponentState.Error)]
    public async Task WebSocketProbeMapsConnectionStatus(string status, ComponentState expected)
    {
        var state = new HaConnectionState();
        state.Set(Enum.Parse<HaConnectionStatus>(status));
        var probe = new HaWebSocketProbe(state);

        ComponentHealth health = await probe.CheckAsync(CancellationToken.None);

        probe.ComponentName.Should().Be("ha_websocket");
        health.State.Should().Be(expected);
        health.Description.Should().NotBeNullOrWhiteSpace();
        health.Description.Should().NotContainAny("http", "ws:", "wss:", "8123", "Bearer");
    }

    [Fact(DisplayName = "Каждый статус соединения имеет отображение в пробе")]
    public async Task EveryStatusIsMapped()
    {
        var state = new HaConnectionState();
        var probe = new HaWebSocketProbe(state);

        foreach (HaConnectionStatus status in Enum.GetValues<HaConnectionStatus>())
        {
            state.Set(status);
            Func<Task> act = () => probe.CheckAsync(CancellationToken.None);
            await act.Should().NotThrowAsync(status.ToString());
        }
    }

    [Fact(DisplayName = "Смена статуса запоминает время и уведомляет подписчика, повтор — нет")]
    public void StateRecordsTransitions()
    {
        var state = new HaConnectionState();
        var seen = new List<HaConnectionStatus>();
        state.StatusChanged += (_, status) => seen.Add(status);
        DateTimeOffset before = DateTimeOffset.UtcNow;

        state.Set(HaConnectionStatus.Connected);
        state.Set(HaConnectionStatus.Connected);
        state.Set(HaConnectionStatus.Reconnecting);

        seen.Should().Equal(HaConnectionStatus.Connected, HaConnectionStatus.Reconnecting);
        state.Status.Should().Be(HaConnectionStatus.Reconnecting);
        state.ChangedAt.Should().BeOnOrAfter(before);
    }
}
