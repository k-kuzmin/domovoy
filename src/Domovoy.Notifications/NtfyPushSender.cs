using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Notifications;

/// <summary>
/// Отправка уведомлений в self-hosted ntfy.
///
/// Каркас: реализация появляется на этапе 3. Имя топика функционально
/// является паролем и не попадает ни в логи, ни в сообщения об ошибках.
/// </summary>
internal sealed class NtfyPushSender : IPushSender
{
    private readonly HttpClient _httpClient;
    private readonly NtfyOptions _options;
    private readonly ILogger<NtfyPushSender> _logger;

    public NtfyPushSender(
        HttpClient httpClient,
        IOptions<NtfyOptions> options,
        ILogger<NtfyPushSender> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _options = options.Value;
        _logger = logger;
    }

    public Task SendAsync(PushNotification notification, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 3: публикация в топик с маппингом приоритетов ntfy.");
}
