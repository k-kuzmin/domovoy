using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;

namespace Domovoy.Tests.Ha;

/// <summary>Запись лога, собранная <see cref="CapturingLoggerProvider"/>.</summary>
internal sealed record CapturedLogEntry(
    string Category,
    LogLevel Level,
    string Message,
    Exception? Exception,
    IReadOnlyList<KeyValuePair<string, object?>> Properties);

/// <summary>
/// Провайдер логов для тестов: копит отрендеренные сообщения, исключения и
/// свойства на всех уровнях, включая Trace. Проверка «секрет не попал в
/// лог» идёт по всем трём, а не по одному тексту сообщения.
/// </summary>
internal sealed class CapturingLoggerProvider : ILoggerProvider
{
    private readonly ConcurrentQueue<CapturedLogEntry> _entries = new();

    public IReadOnlyList<CapturedLogEntry> Entries => _entries.ToArray();

    public ILogger CreateLogger(string categoryName) => new CapturingLogger(categoryName, _entries);

    /// <summary>Записи, в которых маркер встречается в сообщении, исключении или значении свойства.</summary>
    public IReadOnlyList<CapturedLogEntry> EntriesContaining(string marker) =>
        Entries
            .Where(entry =>
                entry.Message.Contains(marker, StringComparison.Ordinal)
                || (entry.Exception?.ToString().Contains(marker, StringComparison.Ordinal) ?? false)
                || entry.Properties.Any(property =>
                    Convert.ToString(property.Value, System.Globalization.CultureInfo.InvariantCulture)
                        ?.Contains(marker, StringComparison.Ordinal) ?? false))
            .ToArray();

    public void Dispose()
    {
    }

    private sealed class CapturingLogger(string category, ConcurrentQueue<CapturedLogEntry> entries) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            IReadOnlyList<KeyValuePair<string, object?>> properties =
                state is IEnumerable<KeyValuePair<string, object?>> pairs ? [.. pairs] : [];

            entries.Enqueue(new CapturedLogEntry(category, logLevel, formatter(state, exception), exception, properties));
        }
    }
}
