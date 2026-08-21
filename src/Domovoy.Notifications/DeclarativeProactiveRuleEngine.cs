using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Notifications;

/// <summary>
/// Правила проактивности из декларативного конфига (FR-PRO-2).
///
/// Решение об отправке принимает правило, не LLM: модель привлекается
/// только для формулировки текста (FR-PRO-4).
///
/// Каркас: реализация появляется на этапе 3.
/// </summary>
internal sealed class DeclarativeProactiveRuleEngine : IProactiveRuleEngine
{
    private readonly ProactivityOptions _options;
    private readonly ILogger<DeclarativeProactiveRuleEngine> _logger;

    public DeclarativeProactiveRuleEngine(
        IOptions<ProactivityOptions> options,
        ILogger<DeclarativeProactiveRuleEngine> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
        _logger = logger;
    }

    public Task<PushNotification?> EvaluateAsync(HaStateChange change, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 3: разбор правил, антиспам-окно, приоритеты.");
}
