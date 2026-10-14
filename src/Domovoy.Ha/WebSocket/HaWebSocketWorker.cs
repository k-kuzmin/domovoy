using System.Buffers;
using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Domovoy.Ha.State;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha.WebSocket;

/// <summary>
/// Постоянное WebSocket-соединение с Home Assistant: подписка на
/// <c>state_changed</c>, кэш состояний и реконнект (FR-HA-3, NFR-PERF-7).
///
/// Попытка: connect и вход под одним крайним сроком
/// <see cref="HaWebSocketTimings.HandshakeTimeout"/> → <c>subscribe_events</c>
/// и <c>get_states</c> без жёсткого срока, под проверкой живости →
/// <see cref="HaStateCache.ReplaceAll"/> → Connected. Живость: после тишины
/// <see cref="HaWebSocketTimings.IdleBeforePing"/> — прикладной ping, и если
/// за <see cref="HaWebSocketTimings.PongTimeout"/> не пришло ни одного кадра,
/// соединение считается оборванным. Медленный, но живой HA обрывом не
/// считается.
///
/// Обрыв — статус Reconnecting сразу и пауза по
/// <see cref="ReconnectBackoff"/>. Во время паузы воркер опрашивает REST
/// <c>GET api/</c>: первый ответ (любой HTTP-ответ, включая 401 и 5xx)
/// заканчивает паузу, и попытка идёт сразу. Исключение — отклонённый токен:
/// пауза строго по расписанию, без опроса: частые попытки отклонённый
/// токен не оживят, а HA может считать их неудачными входами (ip_ban;
/// поведение WebSocket-входа с исходником HA не сверено).
///
/// Токен уходит только в кадре auth и заголовке опроса. Ни кадры, ни
/// исключения в лог не попадают: текст исключения может цитировать кадр
/// или адрес, поэтому пишется только имя типа.
/// </summary>
internal sealed class HaWebSocketWorker : BackgroundService
{
    /// <summary>Именованный клиент опроса готовности — тот же, что у пробы REST.</summary>
    internal const string ProbeClientName = HaServiceCollectionExtensions.HttpClientName + "-probe";

    /// <summary>Предел одного сообщения: ответ get_states большого дома — мегабайты, не сотни.</summary>
    private const int MaxMessageBytes = 64 * 1024 * 1024;

    private const int ReceiveBufferBytes = 16 * 1024;

    private readonly HaOptions _options;
    private readonly IEntityAllowList _allowList;
    private readonly HaStateCache _cache;
    private readonly HaConnectionState _state;
    private readonly HaEventSource _events;
    private readonly IReconnectDelay _delay;
    private readonly HaWebSocketTimings _timings;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<HaWebSocketWorker> _logger;

    public HaWebSocketWorker(
        IOptions<HaOptions> options,
        IEntityAllowList allowList,
        HaStateCache cache,
        HaConnectionState state,
        HaEventSource events,
        IReconnectDelay delay,
        HaWebSocketTimings timings,
        IHttpClientFactory httpClientFactory,
        ILogger<HaWebSocketWorker> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
        _allowList = allowList;
        _cache = cache;
        _state = state;
        _events = events;
        _delay = delay;
        _timings = timings;
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    private enum SessionOutcome
    {
        /// <summary>Обрыв до Connected.</summary>
        Broken,

        /// <summary>Обрыв после Connected: счётчик попыток сбрасывается.</summary>
        BrokenAfterConnected,

        /// <summary>HA ответил auth_invalid.</summary>
        AuthRejected,
    }

    private enum FrameKind
    {
        Message,
        Malformed,
        Closed,
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.IsConfigured)
        {
            _state.Set(HaConnectionStatus.NotConfigured);
            _logger.LogInformation("Токен Home Assistant не задан: WebSocket-соединение не устанавливается");
            return;
        }

        _state.Set(HaConnectionStatus.Connecting);
        int attempt = 0;

        while (!stoppingToken.IsCancellationRequested)
        {
            SessionOutcome outcome;
            try
            {
                outcome = await RunSessionAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }

            if (outcome == SessionOutcome.BrokenAfterConnected)
            {
                attempt = 0;
            }

            bool rejected = outcome == SessionOutcome.AuthRejected;
            _state.Set(rejected ? HaConnectionStatus.AuthRejected : HaConnectionStatus.Reconnecting);

            TimeSpan pause = ReconnectBackoff.Delay(attempt, _options.ReconnectMaxDelaySeconds);
            attempt = attempt == int.MaxValue ? attempt : attempt + 1;
            _logger.LogInformation("Следующая попытка подключения к Home Assistant не позже чем через {PauseSeconds} с", pause.TotalSeconds);

            try
            {
                await PauseAsync(pause, pollRest: !rejected, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Хост не падает из-за сбоя паузы: следующая попытка всё равно идёт.
                _logger.LogWarning("Сбой паузы реконнекта: {ErrorType}", ex.GetType().Name);
            }
        }
    }

    private async Task<SessionOutcome> RunSessionAsync(CancellationToken stoppingToken)
    {
        var session = new Session();
        using var socket = new ClientWebSocket();
        try
        {
            return await RunSessionCoreAsync(socket, session, stoppingToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Любой сбой попытки — обрыв, а не падение хоста. Текст исключения
            // не пишется: в нём может быть адрес или фрагмент кадра.
            _logger.LogWarning("Соединение с Home Assistant прервано: {ErrorType}", ex.GetType().Name);
            return session.BrokenOutcome;
        }
        finally
        {
            socket.Abort();
        }
    }

    private async Task<SessionOutcome> RunSessionCoreAsync(
        ClientWebSocket socket,
        Session session,
        CancellationToken stoppingToken)
    {
        SessionOutcome? handshake = await HandshakeAsync(socket, stoppingToken).ConfigureAwait(false);
        if (handshake is SessionOutcome failed)
        {
            return failed;
        }

        int subscribeId = session.NextId();
        await SendAsync(socket, HaWebSocketProtocol.SubscribeStateChanged(subscribeId), stoppingToken).ConfigureAwait(false);
        int getStatesId = session.NextId();
        await SendAsync(socket, HaWebSocketProtocol.GetStates(getStatesId), stoppingToken).ConfigureAwait(false);

        // События, пришедшие до ответа get_states, применяются после
        // ReplaceAll: применённые сразу, они были бы им же и стёрты. Apply
        // отбросит те из них, что старше снимка.
        var early = new List<JsonElement>();
        bool pingSent = false;
        Task<Frame> receive = ReceiveAsync(socket, stoppingToken);

        try
        {
            while (true)
            {
                using (var timer = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
                {
                    Task silence = Task.Delay(pingSent ? _timings.PongTimeout : _timings.IdleBeforePing, timer.Token);
                    Task first = await Task.WhenAny(receive, silence).ConfigureAwait(false);
                    timer.Cancel();

                    if (first != receive)
                    {
                        stoppingToken.ThrowIfCancellationRequested();
                        if (pingSent)
                        {
                            _logger.LogWarning("Home Assistant не ответил на ping: соединение считается оборванным");
                            return session.BrokenOutcome;
                        }

                        await SendAsync(socket, HaWebSocketProtocol.Ping(session.NextId()), stoppingToken).ConfigureAwait(false);
                        pingSent = true;
                        continue;
                    }
                }

                Frame frame = await receive.ConfigureAwait(false);
                pingSent = false;

                if (frame.Kind == FrameKind.Closed)
                {
                    _logger.LogWarning("Home Assistant закрыл WebSocket-соединение");
                    return session.BrokenOutcome;
                }

                if (frame.Kind == FrameKind.Malformed)
                {
                    _logger.LogWarning("Нечитаемое сообщение Home Assistant пропущено");
                    receive = ReceiveAsync(socket, stoppingToken);
                    continue;
                }

                using (JsonDocument document = frame.Document!)
                {
                    foreach (JsonElement message in Messages(document.RootElement))
                    {
                        if (!HandleMessage(message, session, subscribeId, getStatesId, early))
                        {
                            return session.BrokenOutcome;
                        }
                    }
                }

                receive = ReceiveAsync(socket, stoppingToken);
            }
        }
        finally
        {
            if (!receive.IsCompleted)
            {
                socket.Abort();
            }

            try
            {
                using Frame _ = await receive.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Приём, прерванный обрывом, ошибкой и заканчивается.
            }
        }
    }

    /// <summary>
    /// connect, auth_required и auth_ok под одним крайним сроком.
    /// <c>null</c> — вход выполнен.
    /// </summary>
    private async Task<SessionOutcome?> HandshakeAsync(ClientWebSocket socket, CancellationToken stoppingToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        deadline.CancelAfter(_timings.HandshakeTimeout);

        try
        {
            await socket
                .ConnectAsync(HaWebSocketProtocol.BuildWebSocketUri(_options.BaseUrl), deadline.Token)
                .ConfigureAwait(false);

            using (Frame greeting = await ReceiveAsync(socket, deadline.Token).ConfigureAwait(false))
            {
                if (TypeOf(greeting) != HaWebSocketProtocol.TypeAuthRequired)
                {
                    _logger.LogWarning("Home Assistant не запросил вход: попытка прервана");
                    return SessionOutcome.Broken;
                }
            }

            await SendAsync(socket, HaWebSocketProtocol.Auth(_options.Token!), deadline.Token).ConfigureAwait(false);

            using Frame reply = await ReceiveAsync(socket, deadline.Token).ConfigureAwait(false);
            string? type = TypeOf(reply);
            if (type == HaWebSocketProtocol.TypeAuthInvalid)
            {
                _logger.LogWarning("Home Assistant отклонил токен служебного пользователя");
                return SessionOutcome.AuthRejected;
            }

            if (type != HaWebSocketProtocol.TypeAuthOk)
            {
                _logger.LogWarning("Home Assistant не подтвердил вход: попытка прервана");
                return SessionOutcome.Broken;
            }

            return null;
        }
        catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
        {
            _logger.LogWarning("Подключение и вход в Home Assistant не уложились в срок");
            return SessionOutcome.Broken;
        }
    }

    /// <summary>Обработать одно сообщение. <c>false</c> — соединение надо рвать.</summary>
    private bool HandleMessage(
        JsonElement message,
        Session session,
        int subscribeId,
        int getStatesId,
        List<JsonElement> early)
    {
        string? type = HaWebSocketProtocol.GetString(message, "type");
        int? id = HaWebSocketProtocol.GetInt32(message, "id");

        if (type == HaWebSocketProtocol.TypeResult && id == getStatesId)
        {
            if (!IsSuccess(message)
                || !message.TryGetProperty("result", out JsonElement result)
                || result.ValueKind != JsonValueKind.Array)
            {
                _logger.LogWarning("Home Assistant не отдал состояния: попытка прервана");
                return false;
            }

            _cache.ReplaceAll(ParseStates(result));
            foreach (JsonElement pending in early)
            {
                HandleEvent(pending);
            }

            early.Clear();
            session.Connected = true;
            _state.Set(HaConnectionStatus.Connected);
            _logger.LogInformation(
                "WebSocket-соединение с Home Assistant установлено, сущностей в кэше: {EntityCount}",
                _cache.Snapshot().Count);
            return true;
        }

        if (type == HaWebSocketProtocol.TypeResult && id == subscribeId)
        {
            if (!IsSuccess(message))
            {
                _logger.LogWarning("Home Assistant отказал в подписке на state_changed: попытка прервана");
                return false;
            }

            return true;
        }

        if (type == HaWebSocketProtocol.TypeEvent && message.TryGetProperty("event", out JsonElement @event))
        {
            if (session.Connected)
            {
                HandleEvent(@event);
            }
            else
            {
                early.Add(@event.Clone());
            }
        }

        // pong и незнакомые типы сообщений только подтверждают живость.
        return true;
    }

    private void HandleEvent(JsonElement @event)
    {
        if (HaWebSocketProtocol.GetString(@event, "event_type") != HaWebSocketProtocol.EventStateChanged
            || !@event.TryGetProperty("data", out JsonElement data)
            || HaWebSocketProtocol.GetString(data, "entity_id") is not string entityId)
        {
            return;
        }

        if (!data.TryGetProperty("new_state", out JsonElement newState) || newState.ValueKind == JsonValueKind.Null)
        {
            // Сущность удалена в HA. HaStateChange без Current не строится,
            // подписчикам ничего не уходит. Метка удаления сравнивается с
            // записью, как у Apply: раннее событие из буфера применяется после
            // снимка get_states и не должно стереть то, что в снимке новее.
            DateTimeOffset? removedAt = TryParseTimestamp(@event, "time_fired")
                ?? TryParseState(data, "old_state")?.LastUpdated;
            _cache.Remove(entityId, removedAt);
            return;
        }

        HaEntityState current;
        try
        {
            current = HaWebSocketProtocol.ParseState(newState);
        }
        catch (JsonException)
        {
            _logger.LogWarning("Нечитаемое состояние в событии state_changed пропущено");
            return;
        }

        var change = new HaStateChange
        {
            EntityId = entityId,
            Previous = TryParseState(data, "old_state"),
            Current = current,
            OccurredAt = TryParseTimestamp(@event, "time_fired") ?? current.LastUpdated,
        };

        if (_cache.Apply(change))
        {
            _events.Publish(change);
        }
    }

    /// <summary>
    /// Разобрать ответ get_states, отбросив сущности вне allow-list до
    /// разбора — как REST-путь: объект чужой сущности не разбирается вовсе.
    /// </summary>
    private List<HaEntityState> ParseStates(JsonElement result)
    {
        var states = new List<HaEntityState>();
        int skipped = 0;
        foreach (JsonElement element in result.EnumerateArray())
        {
            if (HaWebSocketProtocol.GetString(element, "entity_id") is not string entityId
                || _allowList.Find(entityId) is null)
            {
                continue;
            }

            try
            {
                states.Add(HaWebSocketProtocol.ParseState(element));
            }
            catch (JsonException)
            {
                skipped++;
            }
        }

        if (skipped > 0)
        {
            _logger.LogWarning("Нечитаемых состояний в ответе get_states: {SkippedCount}", skipped);
        }

        return states;
    }

    private async Task PauseAsync(TimeSpan pause, bool pollRest, CancellationToken stoppingToken)
    {
        using var cut = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        Task wait = _delay.WaitAsync(pause, cut.Token);
        Task[] racers = pollRest ? [wait, PollUntilRestAnswersAsync(cut.Token)] : [wait];

        try
        {
            await Task.WhenAny(racers).ConfigureAwait(false);
        }
        finally
        {
            cut.Cancel();
            foreach (Task racer in racers)
            {
                try
                {
                    await racer.ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // Проигравший гонку отменён — это и есть конец паузы.
                }
            }
        }

        stoppingToken.ThrowIfCancellationRequested();
    }

    /// <summary>
    /// Опрос REST через интервал, 2 интервала … от начала паузы; соседние
    /// опросы — не чаще интервала. Завершается на первом ответе.
    /// </summary>
    private async Task PollUntilRestAnswersAsync(CancellationToken cancellationToken)
    {
        long started = Stopwatch.GetTimestamp();
        TimeSpan nextDue = _timings.ReadinessPollInterval;

        while (true)
        {
            // Таймер может проснуться на миллисекунды раньше срока: остаток
            // дожидается, иначе опрос ушёл бы раньше интервала.
            TimeSpan wait;
            while ((wait = nextDue - Stopwatch.GetElapsedTime(started)) > TimeSpan.Zero)
            {
                await Task.Delay(wait < TimeSpan.FromMilliseconds(1) ? TimeSpan.FromMilliseconds(1) : wait, cancellationToken)
                    .ConfigureAwait(false);
            }

            TimeSpan pollStarted = Stopwatch.GetElapsedTime(started);
            if (await RestAnswersAsync(cancellationToken).ConfigureAwait(false))
            {
                _logger.LogInformation("REST Home Assistant отвечает: пауза реконнекта прервана");
                return;
            }

            nextDue = TimeSpan.FromTicks(Math.Max(
                (nextDue + _timings.ReadinessPollInterval).Ticks,
                (pollStarted + _timings.ReadinessPollInterval).Ticks));
        }
    }

    /// <summary>Любой HTTP-ответ, включая 401 и 5xx, — HTTP-сервер HA жив.</summary>
    private async Task<bool> RestAnswersAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timings.ReadinessPollTimeout);

        using HttpClient client = _httpClientFactory.CreateClient(ProbeClientName);
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_options.BaseUrl.TrimEnd('/') + "/api/"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _options.Token);

        try
        {
            using HttpResponseMessage response = await client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (HttpRequestException)
        {
            return false;
        }
    }

    private static async Task SendAsync(ClientWebSocket socket, byte[] message, CancellationToken cancellationToken) =>
        await socket
            .SendAsync(message, WebSocketMessageType.Text, endOfMessage: true, cancellationToken)
            .ConfigureAwait(false);

    private static async Task<Frame> ReceiveAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        byte[] buffer = ArrayPool<byte>.Shared.Rent(ReceiveBufferBytes);
        try
        {
            using var stream = new MemoryStream();
            while (true)
            {
                ValueWebSocketReceiveResult result = await socket
                    .ReceiveAsync(buffer.AsMemory(), cancellationToken)
                    .ConfigureAwait(false);

                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return new Frame(FrameKind.Closed, null);
                }

                stream.Write(buffer, 0, result.Count);
                if (stream.Length > MaxMessageBytes)
                {
                    throw new InvalidDataException("Сообщение Home Assistant больше допустимого.");
                }

                if (result.EndOfMessage)
                {
                    break;
                }
            }

            try
            {
                return new Frame(FrameKind.Message, JsonDocument.Parse(stream.ToArray()));
            }
            catch (JsonException)
            {
                return new Frame(FrameKind.Malformed, null);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static IEnumerable<JsonElement> Messages(JsonElement root) =>
        root.ValueKind == JsonValueKind.Array ? root.EnumerateArray() : [root];

    private static string? TypeOf(Frame frame) =>
        frame.Kind == FrameKind.Message ? HaWebSocketProtocol.GetString(frame.Document!.RootElement, "type") : null;

    private static bool IsSuccess(JsonElement message) =>
        message.TryGetProperty("success", out JsonElement success) && success.ValueKind == JsonValueKind.True;

    private static HaEntityState? TryParseState(JsonElement data, string name)
    {
        if (!data.TryGetProperty(name, out JsonElement state) || state.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        try
        {
            return HaWebSocketProtocol.ParseState(state);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static DateTimeOffset? TryParseTimestamp(JsonElement element, string name) =>
        HaWebSocketProtocol.GetString(element, name) is string raw
        && DateTimeOffset.TryParse(
            raw,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal,
            out DateTimeOffset value)
            ? value
            : null;

    /// <summary>Состояние одной попытки.</summary>
    private sealed class Session
    {
        private int _lastId;

        public bool Connected { get; set; }

        public SessionOutcome BrokenOutcome =>
            Connected ? SessionOutcome.BrokenAfterConnected : SessionOutcome.Broken;

        /// <summary>Идентификаторы сообщений растут в пределах соединения.</summary>
        public int NextId() => ++_lastId;
    }

    /// <summary>Принятое сообщение. Владеет документом.</summary>
    private readonly record struct Frame(FrameKind Kind, JsonDocument? Document) : IDisposable
    {
        public void Dispose() => Document?.Dispose();
    }
}
