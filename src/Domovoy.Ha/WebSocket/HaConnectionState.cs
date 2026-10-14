namespace Domovoy.Ha.WebSocket;

/// <summary>Статус WebSocket-соединения с Home Assistant.</summary>
internal enum HaConnectionStatus
{
    /// <summary>Токен не задан: соединение не устанавливается вовсе.</summary>
    NotConfigured,

    /// <summary>Первая попытка после старта ещё не завершилась.</summary>
    Connecting,

    /// <summary>
    /// Подписка и кэш актуальны: <c>get_states</c> этого соединения
    /// применён. Только в этом статусе кэш отдаётся как актуальный.
    /// </summary>
    Connected,

    /// <summary>Соединение потеряно, идёт пауза или следующая попытка.</summary>
    Reconnecting,

    /// <summary>HA ответил <c>auth_invalid</c>: токен отклонён.</summary>
    AuthRejected,
}

/// <summary>
/// Текущий статус соединения и время его последней смены. Пишет воркер,
/// читают проба <c>ha_websocket</c> и чтение состояний. Потокобезопасен.
/// </summary>
internal sealed class HaConnectionState
{
    private readonly object _sync = new();
    private HaConnectionStatus _status = HaConnectionStatus.Connecting;
    private DateTimeOffset _changedAt = DateTimeOffset.UtcNow;

    /// <summary>
    /// Смена статуса. Вызывается вне блокировки, в потоке воркера:
    /// обработчик не должен блокировать надолго.
    /// </summary>
    public event EventHandler<HaConnectionStatus>? StatusChanged;

    public HaConnectionStatus Status
    {
        get
        {
            lock (_sync)
            {
                return _status;
            }
        }
    }

    public DateTimeOffset ChangedAt
    {
        get
        {
            lock (_sync)
            {
                return _changedAt;
            }
        }
    }

    /// <summary>Установить статус. Повтор того же статуса не считается сменой.</summary>
    public void Set(HaConnectionStatus status)
    {
        lock (_sync)
        {
            if (_status == status)
            {
                return;
            }

            _status = status;
            _changedAt = DateTimeOffset.UtcNow;
        }

        StatusChanged?.Invoke(this, status);
    }
}
