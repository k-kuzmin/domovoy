using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Domovoy.Ha.Registry;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// REST-клиент Home Assistant.
///
/// <see cref="CallServiceAsync"/> — единственная точка проверки allow-list
/// для действий (FR-HA-4, правила 5 и 6 раздела «Безопасность»): все
/// проверки идут до HTTP-запроса, сервис и поле значения выводятся из
/// каталога доменов, а не из аргументов. <see cref="GetStatesAsync"/> отдаёт
/// кэш только при актуальном соединении, иначе читает REST.
///
/// Токен приходит из <see cref="HaOptions"/> и не логируется никогда; тела
/// ответов HA, адрес и текст исключений не попадают ни в лог, ни в
/// <see cref="ToolResult.Error"/>.
/// </summary>
internal sealed class HaRestClient : IHaClient
{
    private const string StatesPath = "api/states";
    private const string UnavailableMessage = "Home Assistant недоступен.";

    private readonly HttpClient _httpClient;
    private readonly IEntityAllowList _allowList;
    private readonly HaStateCache _cache;
    private readonly HaConnectionState _connection;
    private readonly HaOptions _options;
    private readonly ILogger<HaRestClient> _logger;

    public HaRestClient(
        HttpClient httpClient,
        IEntityAllowList allowList,
        HaStateCache cache,
        HaConnectionState connection,
        IOptions<HaOptions> options,
        ILogger<HaRestClient> logger)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        ArgumentNullException.ThrowIfNull(allowList);
        ArgumentNullException.ThrowIfNull(cache);
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(logger);

        _httpClient = httpClient;
        _allowList = allowList;
        _cache = cache;
        _connection = connection;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<IReadOnlyList<HaEntityState>> GetStatesAsync(
        string? area,
        string? domain,
        CancellationToken cancellationToken)
    {
        // Кэш актуален только при Connected: статус ставится после того, как
        // get_states этого соединения применён. В любом другом статусе кэш
        // может отставать, и чтение идёт в REST.
        IEnumerable<HaEntityState> states = _connection.Status == HaConnectionStatus.Connected
            ? _cache.Snapshot()
            : await ReadStatesFromRestAsync(cancellationToken).ConfigureAwait(false);

        return states.Where(state => Matches(state.EntityId, area, domain)).ToArray();
    }

    public async Task<ToolResult> CallServiceAsync(
        string domain,
        string action,
        string entityId,
        string? value,
        CancellationToken cancellationToken)
    {
        HaEntityDescriptor? descriptor = _allowList.Find(entityId);
        if (descriptor is null)
        {
            return Refusal(HaErrorCodes.EntityNotAllowed, "Сущности нет в списке разрешённых.");
        }

        if (!string.Equals(domain, descriptor.Domain, StringComparison.Ordinal)
            || !_allowList.IsActionAllowed(entityId, action))
        {
            return Refusal(HaErrorCodes.ActionNotAllowed, "Действие не разрешено для этой сущности.");
        }

        // Чтение идёт через GetStatesAsync: у read нет сервиса.
        if (string.Equals(action, HaDomainCatalog.ReadAction, StringComparison.Ordinal))
        {
            return Refusal(HaErrorCodes.ActionNotAllowed, "Чтение состояния — не вызов действия.");
        }

        // Реестр проверен на старте, но каталог — последнее слово: действие,
        // которого в нём нет, не превращается ни в какой сервис.
        HaActionSpec? spec = HaDomainCatalog.Resolve(domain, action);
        if (spec is null)
        {
            return Refusal(HaErrorCodes.ActionNotAllowed, "Действие не входит в каталог домена.");
        }

        if (!HaDomainCatalog.TryBuildPayload(spec, entityId, value, out JsonObject payload))
        {
            return Refusal(HaErrorCodes.InvalidValue, "Значение не подходит для этого действия.");
        }

        // Каталог требует подтверждения независимо от реестра; флаг реестра
        // подтверждение только добавляет.
        if (spec.RequiresConfirmation || descriptor.RequiresConfirmation)
        {
            return Refusal(HaErrorCodes.ConfirmationRequired, "Действие требует подтверждения.") with
            {
                RequiresConfirmation = true,
            };
        }

        if (!_options.IsConfigured)
        {
            return Refusal(HaErrorCodes.HaUnavailable, UnavailableMessage);
        }

        try
        {
            using var request = CreateRequest(HttpMethod.Post, $"api/services/{domain}/{spec.Service}");
            request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");

            using HttpResponseMessage response = await _httpClient
                .SendAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning(
                    "Home Assistant ответил {StatusCode} на вызов {Domain}.{Service}",
                    (int)response.StatusCode,
                    domain,
                    spec.Service);
                return Refusal(HaErrorCodes.HaUnavailable, UnavailableMessage);
            }

            return new ToolResult { ToolCallId = ToolResult.DirectCallId, Success = true };
        }
        catch (Exception ex) when (IsTransportFailure(ex, cancellationToken))
        {
            LogTransportFailure(ex);
            return Refusal(HaErrorCodes.HaUnavailable, UnavailableMessage);
        }
    }

    public Task<IReadOnlyList<HaEntityState>> GetHistoryAsync(
        string entityId,
        int hours,
        CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: история значений для инструмента get_history.");

    public Task<ToolResult> RunScriptAsync(string scriptId, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 2: запуск сценария для инструмента run_script.");

    private async Task<IReadOnlyList<HaEntityState>> ReadStatesFromRestAsync(CancellationToken cancellationToken)
    {
        if (!_options.IsConfigured)
        {
            throw new HaUnavailableException();
        }

        try
        {
            using var request = CreateRequest(HttpMethod.Get, StatesPath);
            using HttpResponseMessage response = await _httpClient
                .SendAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogWarning("Home Assistant ответил {StatusCode} на чтение состояний", (int)response.StatusCode);
                throw new HaUnavailableException();
            }

            Stream body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using (body.ConfigureAwait(false))
            {
                using JsonDocument document = await JsonDocument
                    .ParseAsync(body, cancellationToken: cancellationToken)
                    .ConfigureAwait(false);

                return ParseAllowedStates(document.RootElement);
            }
        }
        catch (JsonException ex)
        {
            // Текст исключения может цитировать ответ — в лог идёт только тип.
            _logger.LogWarning("Ответ Home Assistant на чтение состояний не разобран: {ExceptionType}", ex.GetType().Name);
            throw new HaUnavailableException(ex);
        }
        catch (Exception ex) when (IsTransportFailure(ex, cancellationToken))
        {
            LogTransportFailure(ex);
            throw new HaUnavailableException(ex);
        }
    }

    /// <summary>
    /// Разобрать массив состояний, отбросив сущности вне allow-list до
    /// разбора: объект чужой сущности не разбирается вовсе.
    /// </summary>
    private List<HaEntityState> ParseAllowedStates(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("Ответ на чтение состояний — не массив.");
        }

        var states = new List<HaEntityState>();
        foreach (JsonElement element in root.EnumerateArray())
        {
            if (element.ValueKind == JsonValueKind.Object
                && element.TryGetProperty("entity_id", out JsonElement id)
                && id.ValueKind == JsonValueKind.String
                && _allowList.Find(id.GetString()!) is not null)
            {
                states.Add(HaWebSocketProtocol.ParseState(element));
            }
        }

        return states;
    }

    private bool Matches(string entityId, string? area, string? domain)
    {
        HaEntityDescriptor? descriptor = _allowList.Find(entityId);

        return descriptor is not null
            && (area is null || string.Equals(descriptor.Area, area, StringComparison.Ordinal))
            && (domain is null || string.Equals(descriptor.Domain, domain, StringComparison.Ordinal));
    }

    private HttpRequestMessage CreateRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.Token);
        return request;
    }

    /// <summary>
    /// Сетевая ошибка или таймаут клиента. Отмена вызывающей стороной сюда не
    /// относится и пробрасывается как есть.
    /// </summary>
    private static bool IsTransportFailure(Exception exception, CancellationToken cancellationToken) =>
        exception is HttpRequestException
        || (exception is TaskCanceledException && !cancellationToken.IsCancellationRequested);

    // Само исключение в лог не передаётся: его текст содержит адрес HA.
    private void LogTransportFailure(Exception exception) =>
        _logger.LogWarning("Home Assistant недоступен: {ExceptionType}", exception.GetType().Name);

    private static ToolResult Refusal(string errorCode, string error) => new()
    {
        ToolCallId = ToolResult.DirectCallId,
        Success = false,
        Error = error,
        ErrorCode = errorCode,
    };
}
