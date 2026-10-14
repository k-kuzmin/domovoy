namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Ожидание паузы реконнекта. Шов для тестов: настоящая пауза — секунды,
/// тест подменяет её записью длительности или ожиданием одной отмены.
/// Ожидание обязано прерываться отменой: на нём держится досрочный конец
/// паузы, когда Home Assistant снова отвечает.
/// </summary>
internal interface IReconnectDelay
{
    Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken);
}

/// <summary>Пауза реальным временем.</summary>
internal sealed class SystemReconnectDelay : IReconnectDelay
{
    public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, cancellationToken);
}
