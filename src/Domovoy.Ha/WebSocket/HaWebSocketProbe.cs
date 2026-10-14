using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Проба WebSocket-соединения с Home Assistant — отдельный компонент
/// <c>ha_websocket</c> в <c>/api/v1/health</c> (NFR-OBS-3).
///
/// Соединение не проверяется заново, а читается статус воркера. Переподключение
/// — Unreachable и тогда, когда REST HA отвечает: по записи 0010 это
/// unhealthy, кэш в это время как актуальный не отдаётся.
/// </summary>
internal sealed class HaWebSocketProbe : IComponentProbe
{
    private readonly HaConnectionState _state;

    public HaWebSocketProbe(HaConnectionState state)
    {
        ArgumentNullException.ThrowIfNull(state);

        _state = state;
    }

    public string ComponentName => "ha_websocket";

    public Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken) =>
        Task.FromResult(_state.Status switch
        {
            HaConnectionStatus.Connected => ComponentHealth.Ok("соединение установлено"),
            HaConnectionStatus.NotConfigured => ComponentHealth.NotConfigured("токен служебного пользователя не задан"),
            HaConnectionStatus.AuthRejected => ComponentHealth.Error("токен отклонён"),
            HaConnectionStatus.Connecting or HaConnectionStatus.Reconnecting =>
                ComponentHealth.Unreachable("переподключение"),
            _ => ComponentHealth.Error("неизвестный статус соединения"),
        });
}
