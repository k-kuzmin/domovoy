using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Domovoy.Tests.Ha;

/// <summary>Поведение WebSocket-входа фейка.</summary>
internal enum FakeWebSocketMode
{
    /// <summary>Обычный HA: auth_required, вход, подписка, get_states.</summary>
    Accept,

    /// <summary>HTTP-сервер жив, апгрейд отклоняется ответом 503.</summary>
    RejectUpgrade,

    /// <summary>Соединение рвётся без ответа — HA лежит.</summary>
    Down,

    /// <summary>Апгрейд принят, но auth_required не приходит никогда.</summary>
    NoAuthRequired,
}

/// <summary>Запрос к REST фейка.</summary>
internal sealed record FakeRestRequest(
    string Method,
    string Path,
    string Body,
    bool HasAuthorization,
    bool AuthorizedWithExpectedToken);

/// <summary>
/// Фейковый Home Assistant на Kestrel (127.0.0.1, свободный порт):
/// WebSocket API (<c>/api/websocket</c>) и REST (<c>GET /api/</c>,
/// <c>GET /api/states</c>, <c>POST /api/services/{domain}/{service}</c>).
///
/// REST и WebSocket включаются и выключаются раздельно. «Выключен» —
/// соединение обрывается без HTTP-ответа: ответ с любым кодом означал бы
/// живой HTTP-сервер. Состояния хранятся в фейке и отдаются одинаково
/// через get_states и REST; каждая правка ставит новую, строго растущую
/// метку last_updated.
/// </summary>
internal sealed class FakeHomeAssistant : IAsyncDisposable
{
    private static readonly DateTimeOffset ClockStart = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

    private readonly WebApplication _app;
    private readonly object _sync = new();
    private readonly Dictionary<string, JsonObject> _states = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<int, Connection> _connections = new();
    private readonly ConcurrentQueue<TimeSpan> _apiRootRequests = new();
    private readonly ConcurrentQueue<FakeRestRequest> _restRequests = new();
    private readonly ConcurrentQueue<string> _subscribedEventTypes = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private DateTimeOffset _lastStamp = ClockStart;
    private int _nextConnectionId;
    private int _webSocketRequests;
    private int _authCount;
    private int _subscribeCount;
    private int _getStatesCount;
    private int _pingCount;
    private string? _lastAuthToken;

    private volatile bool _restAvailable = true;
    private volatile FakeWebSocketMode _webSocketMode = FakeWebSocketMode.Accept;
    private volatile bool _respondToPing = true;
    private volatile bool _silentAfterAuth;
    private volatile string _expectedToken;
    private long _getStatesDelayTicks;

    private FakeHomeAssistant(WebApplication app, string expectedToken)
    {
        _app = app;
        _expectedToken = expectedToken;
    }

    /// <summary>Адрес вида <c>http://127.0.0.1:port</c>.</summary>
    public string BaseUrl { get; private set; } = string.Empty;

    /// <summary>Токен, который WebSocket-вход принимает; любой другой — auth_invalid.</summary>
    public string ExpectedToken
    {
        get => _expectedToken;
        set => _expectedToken = value;
    }

    public bool RestAvailable
    {
        get => _restAvailable;
        set => _restAvailable = value;
    }

    public FakeWebSocketMode WebSocketMode
    {
        get => _webSocketMode;
        set => _webSocketMode = value;
    }

    /// <summary>Отвечать pong на ping.</summary>
    public bool RespondToPing
    {
        get => _respondToPing;
        set => _respondToPing = value;
    }

    /// <summary>После auth_ok не отвечать ни на что: ни на подписку, ни на get_states, ни на ping.</summary>
    public bool SilentAfterAuth
    {
        get => _silentAfterAuth;
        set => _silentAfterAuth = value;
    }

    /// <summary>Задержка ответа на get_states; приём кадров она не блокирует.</summary>
    public TimeSpan GetStatesDelay
    {
        get => TimeSpan.FromTicks(Interlocked.Read(ref _getStatesDelayTicks));
        set => Interlocked.Exchange(ref _getStatesDelayTicks, value.Ticks);
    }

    /// <summary>Код ответа <c>GET /api/states</c>.</summary>
    public HttpStatusCode StatesStatusCode { get; set; } = HttpStatusCode.OK;

    /// <summary>Код ответа <c>POST /api/services/…</c>.</summary>
    public HttpStatusCode ServiceStatusCode { get; set; } = HttpStatusCode.OK;

    /// <summary>Запросов к <c>/api/websocket</c>, включая отклонённые.</summary>
    public int WebSocketRequestCount => Volatile.Read(ref _webSocketRequests);

    public int AuthCount => Volatile.Read(ref _authCount);

    public int SubscribeCount => Volatile.Read(ref _subscribeCount);

    public int GetStatesCount => Volatile.Read(ref _getStatesCount);

    public int PingCount => Volatile.Read(ref _pingCount);

    public string? LastAuthToken => Volatile.Read(ref _lastAuthToken);

    public IReadOnlyList<string> SubscribedEventTypes => _subscribedEventTypes.ToArray();

    /// <summary>Моменты запросов <c>GET /api/</c> от старта фейка, включая оборванные.</summary>
    public IReadOnlyList<TimeSpan> ApiRootRequests => _apiRootRequests.ToArray();

    /// <summary>Запросы к <c>/api/states</c> и <c>/api/services/…</c>.</summary>
    public IReadOnlyList<FakeRestRequest> RestRequests => _restRequests.ToArray();

    /// <summary>Сколько сокетов прошли вход и ещё открыты.</summary>
    public int OpenConnections => _connections.Count;

    /// <summary>Текущие состояния фейка: entity_id → state.</summary>
    public IReadOnlyDictionary<string, string> CurrentStates
    {
        get
        {
            lock (_sync)
            {
                return _states.ToDictionary(
                    pair => pair.Key,
                    pair => pair.Value["state"]!.GetValue<string>(),
                    StringComparer.Ordinal);
            }
        }
    }

    /// <summary>Время на часах фейка — та же шкала, что у <see cref="ApiRootRequests"/>.</summary>
    public TimeSpan Elapsed => _clock.Elapsed;

    public static async Task<FakeHomeAssistant> StartAsync(string expectedToken)
    {
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));

        WebApplication app = builder.Build();
        var fake = new FakeHomeAssistant(app, expectedToken);
        fake.MapEndpoints();

        await app.StartAsync();
        string address = app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!
            .Addresses.First();
        fake.BaseUrl = address.TrimEnd('/');
        return fake;
    }

    /// <summary>Задать состояние без события.</summary>
    public void SetState(string entityId, string state, IReadOnlyDictionary<string, object?>? attributes = null)
    {
        lock (_sync)
        {
            _states[entityId] = BuildState(entityId, state, attributes, previous: _states.GetValueOrDefault(entityId));
        }
    }

    /// <summary>Удалить сущность без события.</summary>
    public void RemoveState(string entityId)
    {
        lock (_sync)
        {
            _states.Remove(entityId);
        }
    }

    /// <summary>
    /// Изменить состояние и разослать <c>state_changed</c> всем подписанным
    /// соединениям. <paramref name="state"/> = <c>null</c> — сущность удалена,
    /// <c>new_state</c> = null.
    /// </summary>
    public async Task PushStateChangedAsync(
        string entityId,
        string? state,
        IReadOnlyDictionary<string, object?>? attributes = null)
    {
        JsonObject? oldState;
        JsonObject? newState;
        lock (_sync)
        {
            oldState = _states.GetValueOrDefault(entityId);
            if (state is null)
            {
                _states.Remove(entityId);
                newState = null;
            }
            else
            {
                newState = BuildState(entityId, state, attributes, oldState);
                _states[entityId] = newState;
            }
        }

        var message = new JsonObject
        {
            ["id"] = 1,
            ["type"] = "event",
            ["event"] = new JsonObject
            {
                ["event_type"] = "state_changed",
                ["data"] = new JsonObject
                {
                    ["entity_id"] = entityId,
                    ["old_state"] = oldState?.DeepClone(),
                    ["new_state"] = newState?.DeepClone(),
                },
                ["origin"] = "LOCAL",
                ["time_fired"] = Stamp(newState ?? oldState),
            },
        };

        await PushRawAsync(message.ToJsonString());
    }

    /// <summary>Отправить произвольный текст всем подписанным соединениям.</summary>
    public async Task PushRawAsync(string text)
    {
        foreach (Connection connection in _connections.Values.Where(connection => connection.Subscribed))
        {
            await connection.SendAsync(text);
        }
    }

    /// <summary>Оборвать все открытые WebSocket-соединения без закрывающего кадра.</summary>
    public void DropConnections()
    {
        foreach (Connection connection in _connections.Values)
        {
            connection.Abort();
        }
    }

    public async ValueTask DisposeAsync()
    {
        DropConnections();
        await _app.StopAsync();
        await _app.DisposeAsync();
    }

    private void MapEndpoints()
    {
        _app.UseWebSockets();

        _app.Map("/api/websocket", HandleWebSocketAsync);

        _app.MapGet("/api/", (HttpContext context) =>
        {
            _apiRootRequests.Enqueue(_clock.Elapsed);
            if (!RestAvailable)
            {
                context.Abort();
                return Results.Empty;
            }

            return Results.Json(new { message = "API running." });
        });

        _app.MapGet("/api/states", async (HttpContext context) =>
        {
            if (!await RecordRestAsync(context))
            {
                return Results.Empty;
            }

            string body;
            lock (_sync)
            {
                body = new JsonArray([.. _states.Values.Select(state => state.DeepClone())]).ToJsonString();
            }

            return Results.Text(body, "application/json", Encoding.UTF8, (int)StatesStatusCode);
        });

        _app.MapPost("/api/services/{domain}/{service}", async (HttpContext context) =>
        {
            if (!await RecordRestAsync(context))
            {
                return Results.Empty;
            }

            return Results.Text("[]", "application/json", Encoding.UTF8, (int)ServiceStatusCode);
        });
    }

    private async Task<bool> RecordRestAsync(HttpContext context)
    {
        using var reader = new StreamReader(context.Request.Body, Encoding.UTF8);
        string body = await reader.ReadToEndAsync();
        string? authorization = context.Request.Headers.Authorization;
        _restRequests.Enqueue(new FakeRestRequest(
            context.Request.Method,
            context.Request.Path.Value ?? string.Empty,
            body,
            HasAuthorization: !string.IsNullOrEmpty(authorization),
            AuthorizedWithExpectedToken: authorization == "Bearer " + ExpectedToken));

        if (!RestAvailable)
        {
            context.Abort();
            return false;
        }

        return true;
    }

    private async Task HandleWebSocketAsync(HttpContext context)
    {
        Interlocked.Increment(ref _webSocketRequests);
        FakeWebSocketMode mode = WebSocketMode;

        if (mode == FakeWebSocketMode.Down)
        {
            context.Abort();
            return;
        }

        if (mode == FakeWebSocketMode.RejectUpgrade || !context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            return;
        }

        using System.Net.WebSockets.WebSocket socket = await context.WebSockets.AcceptWebSocketAsync();
        using var connection = new Connection(socket);
        int connectionId = Interlocked.Increment(ref _nextConnectionId);

        try
        {
            if (mode == FakeWebSocketMode.NoAuthRequired)
            {
                while (await connection.ReceiveAsync() is not null)
                {
                }

                return;
            }

            await connection.SendAsync("""{"type":"auth_required","ha_version":"2026.1.0"}""");
            JsonElement? auth = await connection.ReceiveAsync();
            if (auth is null || Field(auth.Value, "type") != "auth")
            {
                return;
            }

            Interlocked.Increment(ref _authCount);
            string? token = Field(auth.Value, "access_token");
            Volatile.Write(ref _lastAuthToken, token);

            if (token != ExpectedToken)
            {
                await connection.SendAsync("""{"type":"auth_invalid","message":"Invalid access token or password"}""");
                await connection.CloseAsync();
                return;
            }

            await connection.SendAsync("""{"type":"auth_ok","ha_version":"2026.1.0"}""");
            _connections[connectionId] = connection;

            while (await connection.ReceiveAsync() is JsonElement message)
            {
                HandleCommand(connection, message);
            }
        }
        catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or IOException)
        {
            // Обрыв соединения со стороны клиента или DropConnections.
        }
        finally
        {
            _connections.TryRemove(connectionId, out _);
        }
    }

    private void HandleCommand(Connection connection, JsonElement message)
    {
        string? type = Field(message, "type");
        int id = message.TryGetProperty("id", out JsonElement rawId) && rawId.TryGetInt32(out int value) ? value : 0;

        switch (type)
        {
            case "subscribe_events":
                Interlocked.Increment(ref _subscribeCount);
                _subscribedEventTypes.Enqueue(Field(message, "event_type") ?? string.Empty);
                if (!SilentAfterAuth)
                {
                    connection.Subscribed = true;
                    connection.Post(Result(id, null));
                }

                break;

            case "get_states":
                Interlocked.Increment(ref _getStatesCount);
                if (!SilentAfterAuth)
                {
                    TimeSpan delay = GetStatesDelay;
                    _ = Task.Run(async () =>
                    {
                        await Task.Delay(delay);
                        if (SilentAfterAuth)
                        {
                            return;
                        }

                        JsonArray states;
                        lock (_sync)
                        {
                            states = new JsonArray([.. _states.Values.Select(state => state.DeepClone())]);
                        }

                        await connection.SendAsync(Result(id, states));
                    });
                }

                break;

            case "ping":
                Interlocked.Increment(ref _pingCount);
                if (RespondToPing && !SilentAfterAuth)
                {
                    connection.Post(new JsonObject { ["id"] = id, ["type"] = "pong" }.ToJsonString());
                }

                break;
        }
    }

    private JsonObject BuildState(
        string entityId,
        string state,
        IReadOnlyDictionary<string, object?>? attributes,
        JsonObject? previous)
    {
        DateTimeOffset stamp = NextStamp();
        bool stateChanged = previous is null || previous["state"]!.GetValue<string>() != state;

        var attributeNode = new JsonObject();
        foreach (KeyValuePair<string, object?> attribute in attributes ?? new Dictionary<string, object?>())
        {
            attributeNode[attribute.Key] = JsonSerializer.SerializeToNode(attribute.Value);
        }

        return new JsonObject
        {
            ["entity_id"] = entityId,
            ["state"] = state,
            ["attributes"] = attributeNode,
            ["last_changed"] = stateChanged ? Format(stamp) : previous!["last_changed"]!.DeepClone(),
            ["last_updated"] = Format(stamp),
            ["context"] = new JsonObject { ["id"] = Guid.NewGuid().ToString("N"), ["parent_id"] = null, ["user_id"] = null },
        };
    }

    private DateTimeOffset NextStamp()
    {
        lock (_sync)
        {
            _lastStamp = _lastStamp.AddSeconds(1);
            return _lastStamp;
        }
    }

    private static string Stamp(JsonObject? state) =>
        state?["last_updated"]?.GetValue<string>() ?? Format(ClockStart);

    private static string Format(DateTimeOffset stamp) =>
        stamp.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffffzzz", CultureInfo.InvariantCulture);

    private static string Result(int id, JsonNode? result) =>
        new JsonObject { ["id"] = id, ["type"] = "result", ["success"] = true, ["result"] = result }.ToJsonString();

    private static string? Field(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    /// <summary>Одно WebSocket-соединение фейка; отправки сериализованы.</summary>
    private sealed class Connection : IDisposable
    {
        private readonly SemaphoreSlim _send = new(1, 1);
        private readonly object _gate = new();
        private volatile bool _subscribed;
        private bool _released;

        public Connection(System.Net.WebSockets.WebSocket socket) => Socket = socket;

        public System.Net.WebSockets.WebSocket Socket { get; }

        /// <summary>
        /// Оборвать соединение, если обработчик запроса ещё не завершён:
        /// после завершения контекст Kestrel переиспользуется, и обрыв
        /// задел бы чужой запрос.
        /// </summary>
        public void Abort()
        {
            lock (_gate)
            {
                if (!_released)
                {
                    Socket.Abort();
                }
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _released = true;
            }

            _send.Dispose();
        }

        public bool Subscribed
        {
            get => _subscribed;
            set => _subscribed = value;
        }

        /// <summary>Отправить, не дожидаясь: приём кадров не блокируется.</summary>
        public void Post(string text) => _ = SendAsync(text);

        public async Task SendAsync(string text)
        {
            if (!await TryEnterAsync())
            {
                return;
            }

            try
            {
                if (Socket.State == WebSocketState.Open)
                {
                    await Socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, CancellationToken.None);
                }
            }
            catch (Exception ex) when (ex is WebSocketException or ObjectDisposedException or IOException)
            {
                // Соединение уже оборвано.
            }
            finally
            {
                _send.Release();
            }
        }

        public async Task CloseAsync()
        {
            if (!await TryEnterAsync())
            {
                return;
            }

            try
            {
                await Socket.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
            }
            catch (Exception ex) when (ex is WebSocketException or ObjectDisposedException or IOException)
            {
                // Клиент ушёл раньше.
            }
            finally
            {
                _send.Release();
            }
        }

        /// <summary>Захватить отправку; <c>false</c> — соединение уже освобождено.</summary>
        private async Task<bool> TryEnterAsync()
        {
            try
            {
                await _send.WaitAsync();
                return true;
            }
            catch (ObjectDisposedException)
            {
                return false;
            }
        }

        /// <summary>Следующее сообщение или <c>null</c>, если соединение закрыто.</summary>
        public async Task<JsonElement?> ReceiveAsync()
        {
            byte[] buffer = new byte[16 * 1024];
            using var stream = new MemoryStream();
            while (true)
            {
                WebSocketReceiveResult result = await Socket.ReceiveAsync(buffer, CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return null;
                }

                stream.Write(buffer, 0, result.Count);
                if (result.EndOfMessage)
                {
                    break;
                }
            }

            using JsonDocument document = JsonDocument.Parse(stream.ToArray());
            return document.RootElement.Clone();
        }
    }
}
