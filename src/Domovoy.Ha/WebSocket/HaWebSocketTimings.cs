namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Внутренние сроки WebSocket-соединения. Не параметры конфигурации:
/// бюджет восстановления 60 с (NFR-PERF-7) посчитан от этих значений, и
/// менять их по одному без пересчёта бюджета нельзя. Тесты подменяют их
/// на миллисекунды, сохраняя соотношения.
///
/// Бюджет от готовности HA отдать состояния: <see cref="HandshakeTimeout"/>
/// (попытка в полёте) + <see cref="ReadinessPollInterval"/> +
/// <see cref="ReadinessPollTimeout"/> (пауза) + <see cref="HandshakeTimeout"/>
/// (успешная попытка) + время ответа <c>get_states</c> = 30 с + T.
/// </summary>
internal sealed record HaWebSocketTimings
{
    /// <summary>
    /// Один крайний срок на connect, <c>auth_required</c> и <c>auth_ok</c>.
    /// Ответы <c>subscribe_events</c> и <c>get_states</c> им не ограничены:
    /// их ограничивает только проверка живости.
    /// </summary>
    public TimeSpan HandshakeTimeout { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Тишина, после которой воркер шлёт прикладной ping.</summary>
    public TimeSpan IdleBeforePing { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>Срок, за который после ping должен прийти хоть один кадр.</summary>
    public TimeSpan PongTimeout { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Шаг опроса REST <c>GET api/</c> во время паузы реконнекта.</summary>
    public TimeSpan ReadinessPollInterval { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>Таймаут одного опроса REST во время паузы.</summary>
    public TimeSpan ReadinessPollTimeout { get; init; } = TimeSpan.FromSeconds(5);
}
