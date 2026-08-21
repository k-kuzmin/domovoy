using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Notifications;

/// <summary>
/// Фоновый сервис проактивности (FR-PRO-1): слушает поток событий Home
/// Assistant и отправляет уведомления по правилам.
///
/// На этапе каркаса выключен настройкой. Так и должно быть: включённый
/// сервис немедленно упёрся бы в незаполненную реализацию потока
/// событий и уронил бы хост, а вместе с ним и <c>/health</c>.
/// </summary>
internal sealed class ProactivityWorker : BackgroundService
{
    private readonly IHaEventSource _events;
    private readonly IProactiveRuleEngine _rules;
    private readonly IPushSender _push;
    private readonly ProactivityOptions _options;
    private readonly ILogger<ProactivityWorker> _logger;

    public ProactivityWorker(
        IHaEventSource events,
        IProactiveRuleEngine rules,
        IPushSender push,
        IOptions<ProactivityOptions> options,
        ILogger<ProactivityWorker> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _events = events;
        _rules = rules;
        _push = push;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogInformation(
                "Проактивные уведомления выключены настройкой Proactivity:Enabled, фоновый сервис не запущен.");
            return;
        }

        await foreach (HaStateChange change in _events.SubscribeAsync(stoppingToken).ConfigureAwait(false))
        {
            PushNotification? notification = await _rules
                .EvaluateAsync(change, stoppingToken)
                .ConfigureAwait(false);

            if (notification is not null)
            {
                await _push.SendAsync(notification, stoppingToken).ConfigureAwait(false);
            }
        }
    }
}
