namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Расписание паузы между попытками подключения WebSocket: 1, 2, 4 … с,
/// не больше потолка <c>HaOptions.ReconnectMaxDelaySeconds</c>
/// (FR-HA-3, NFR-PERF-7).
/// </summary>
internal static class ReconnectBackoff
{
    /// <summary>Пауза перед попыткой с номером <paramref name="attempt"/>, считая с 0.</summary>
    public static TimeSpan Delay(int attempt, int maxDelaySeconds)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(attempt);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maxDelaySeconds);

        // 2^30 с заведомо больше любого потолка: сдвиг дальше переполнил бы int.
        int exponent = Math.Min(attempt, 30);
        long seconds = Math.Min(1L << exponent, maxDelaySeconds);

        return TimeSpan.FromSeconds(seconds);
    }
}
