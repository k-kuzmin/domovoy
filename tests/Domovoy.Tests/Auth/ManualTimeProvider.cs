namespace Domovoy.Tests.Auth;

/// <summary>
/// Часы, которые идут только по команде теста: срок кода и частота
/// обновления last_seen проверяются без ожидания реального времени.
/// </summary>
public sealed class ManualTimeProvider : TimeProvider
{
    private readonly object _gate = new();
    private DateTimeOffset _now;

    public ManualTimeProvider()
        : this(new DateTimeOffset(2026, 1, 15, 12, 0, 0, TimeSpan.Zero))
    {
    }

    public ManualTimeProvider(DateTimeOffset start)
    {
        _now = start;
    }

    public override DateTimeOffset GetUtcNow()
    {
        lock (_gate)
        {
            return _now;
        }
    }

    public void Advance(TimeSpan delta)
    {
        lock (_gate)
        {
            _now = _now.Add(delta);
        }
    }
}
