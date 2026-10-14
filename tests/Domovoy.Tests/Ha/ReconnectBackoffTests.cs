using Domovoy.Ha.WebSocket;
using FluentAssertions;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Пауза реконнекта WebSocket: экспоненциальный рост с потолком
/// (FR-HA-3, NFR-PERF-7).
/// </summary>
public sealed class ReconnectBackoffTests
{
    [Fact(DisplayName = "Пауза удваивается с 1 с и упирается в потолок 60 с")]
    public void ReconnectDelayDoublesUpToCeiling()
    {
        int[] expectedSeconds = [1, 2, 4, 8, 16, 32, 60, 60, 60, 60];

        for (int attempt = 0; attempt < expectedSeconds.Length; attempt++)
        {
            ReconnectBackoff.Delay(attempt, maxDelaySeconds: 60)
                .Should().Be(TimeSpan.FromSeconds(expectedSeconds[attempt]), $"попытка {attempt}");
        }
    }

    [Fact(DisplayName = "Пауза не превышает заданный потолок и на больших номерах попыток")]
    public void ReconnectDelayNeverExceedsSmallCeiling()
    {
        int[] attempts = [0, 1, 2, 3, 4, 10, 31, 64, int.MaxValue];

        foreach (int attempt in attempts)
        {
            ReconnectBackoff.Delay(attempt, maxDelaySeconds: 5)
                .Should().BeLessThanOrEqualTo(TimeSpan.FromSeconds(5), $"попытка {attempt}");
        }

        ReconnectBackoff.Delay(2, maxDelaySeconds: 5).Should().Be(TimeSpan.FromSeconds(4));
        ReconnectBackoff.Delay(3, maxDelaySeconds: 5).Should().Be(TimeSpan.FromSeconds(5));
    }

    [Fact(DisplayName = "Отрицательный номер попытки — ошибка вызова")]
    public void NegativeAttemptIsRejected()
    {
        Action act = () => ReconnectBackoff.Delay(-1, maxDelaySeconds: 60);

        act.Should().Throw<ArgumentOutOfRangeException>();
    }

    [Fact(DisplayName = "Системная пауза прерывается отменой")]
    public async Task SystemDelayIsCancellable()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        Func<Task> act = () => new SystemReconnectDelay().WaitAsync(TimeSpan.FromMinutes(5), cts.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }
}
