using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// REST-клиент Home Assistant.
///
/// Каркас: реализация появляется на этапе 1. Токен приходит из
/// <see cref="HaOptions"/> и не логируется никогда.
/// </summary>
internal sealed class HaRestClient : IHaClient
{
    private readonly HttpClient _httpClient;
    private readonly IEntityAllowList _allowList;
    private readonly HaOptions _options;
    private readonly ILogger<HaRestClient> _logger;

    public HaRestClient(
        HttpClient httpClient,
        IEntityAllowList allowList,
        IOptions<HaOptions> options,
        ILogger<HaRestClient> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _httpClient = httpClient;
        _allowList = allowList;
        _options = options.Value;
        _logger = logger;
    }

    public Task<IReadOnlyList<HaEntityState>> GetStatesAsync(
        string? area,
        string? domain,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 1: подписка на состояния и фильтрация по allow-list.");

    public Task<ToolResult> CallServiceAsync(
        string domain,
        string service,
        string entityId,
        string? value,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 1: вызов сервиса с проверкой по белому списку.");

    public Task<IReadOnlyList<HaEntityState>> GetHistoryAsync(
        string entityId,
        int hours,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: история значений для инструмента get_history.");

    public Task<ToolResult> RunScriptAsync(string scriptId, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: запуск сценария для инструмента run_script.");
}
