using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.LiveCheck;

/// <summary>
/// Живые замеры против настоящего Home Assistant — запускает владелец.
///
/// Конфигурация — только переменные окружения: <c>Ha__BaseUrl</c>,
/// <c>Ha__Token</c>, <c>Ha__EntityRegistryPath</c> (относительный путь — от
/// текущего каталога). Воркер, кэш и быстрый путь поднимаются той же
/// регистрацией, что у api (<c>AddDomovoyCore</c> и <c>AddHomeAssistant</c>);
/// контейнер api программа не наблюдает.
///
/// Вывод предназначен для приложения к issue: токена, адреса HA и
/// entity_id в нём нет ни в одном режиме — только статусы, числа и время.
/// Логи хоста не печатаются: HttpClientFactory пишет адреса запросов.
/// </summary>
internal static class Program
{
    private const string ReadAction = "read";

    private static readonly TimeSpan ConnectWait = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RestPollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan RestPollTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan GetStatesWait = TimeSpan.FromSeconds(120);
    private const int MaxMessageBytes = 64 * 1024 * 1024;
    private const int CompareAttempts = 3;

    public static async Task<int> Main(string[] args)
    {
        // Вывод с «», → и кириллицей: кодовая страница консоли Windows по
        // умолчанию их не вмещает, а вывод владелец прикладывает к issue.
        Console.OutputEncoding = Encoding.UTF8;

        using var stop = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            stop.Cancel();
        };

        try
        {
            string mode = args.Length > 0 ? args[0] : string.Empty;

            if (mode == "latency" && LatencyArguments.TryParse(args[1..], out LatencyArguments? parsed))
            {
                return await RunAsync(host => LatencyAsync(host, parsed, stop.Token), stop.Token).ConfigureAwait(false);
            }

            if (mode == "reconnect" && args.Length == 1)
            {
                return await RunAsync(host => ReconnectAsync(host, stop.Token), stop.Token).ConfigureAwait(false);
            }

            return Usage();
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
            Print("остановлено");
            return 0;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine(
            """
            Использование:
              latency --phrases <файл> [--iterations N] [--allow-actions]
                  p50, p95 и max быстрого пути отдельно для чтения и действий.
                  Фразы — по одной в строке, # — комментарий. Без --allow-actions
                  изменяющие фразы пропускаются: устройства не трогаются.
              reconnect
                  Переходы статуса WebSocket и доступности REST с отметкой времени;
                  после каждого Connected — интервал «REST ответил → Connected»,
                  время ответа get_states и сверка кэша с GET api/states.
                  Остановка — Ctrl+C.

            Окружение: Ha__BaseUrl, Ha__Token, Ha__EntityRegistryPath.
            Реестр проверяется в любом режиме до соединения; без Ha__Token
            программа проверяет конфигурацию и реестр и выходит.
            """);
        return 2;
    }

    private static async Task<int> RunAsync(Func<IHost, Task<int>> mode, CancellationToken cancellationToken)
    {
        using IHost host = BuildHost();

        // Проверка конфигурации — до проверки токена: реестр проверяется без
        // соединения с HA, и владелец сверяет реальный реестр до выката, даже
        // не задав Ha__Token.
        // Та же проверка, что старт хоста делает сам (ValidateOnStart), —
        // здесь раньше, чтобы отказ печатался без текста ошибок.
        if (!TryValidateConfiguration(host))
        {
            return 1;
        }

        Print("конфигурация и реестр сущностей прошли проверку");

        if (!host.Services.GetRequiredService<IOptions<HaOptions>>().Value.IsConfigured)
        {
            Print("Ha__Token не задан: соединяться не с чем");
            return 1;
        }

        await host.StartAsync(cancellationToken).ConfigureAwait(false);

        try
        {
            return await mode(host).ConfigureAwait(false);
        }
        finally
        {
            await host.StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Проверка всех опций с ValidateOnStart, реестр сущностей в их числе.
    /// Отказ печатается типом опций и числом ошибок, без текста: вывод
    /// прикладывается к issue, а запись и поле называет старт api.
    /// </summary>
    private static bool TryValidateConfiguration(IHost host)
    {
        try
        {
            host.Services.GetRequiredService<IStartupValidator>().Validate();
            return true;
        }
        catch (OptionsValidationException exception)
        {
            PrintRefusal([exception]);
            return false;
        }
        catch (AggregateException exception) when (exception.InnerExceptions.All(inner => inner is OptionsValidationException))
        {
            // Несколько опций не прошли проверку — по исключению на каждую.
            PrintRefusal(exception.InnerExceptions.Cast<OptionsValidationException>());
            return false;
        }
    }

    private static void PrintRefusal(IEnumerable<OptionsValidationException> exceptions)
    {
        foreach (OptionsValidationException exception in exceptions)
        {
            Print($"конфигурация не прошла проверку ({exception.OptionsType.Name}, ошибок: {exception.Failures.Count()}); подробности — при старте api");
        }
    }

    private static IHost BuildHost()
    {
        // Построитель без источников по умолчанию: ни appsettings, ни
        // user-secrets — только окружение, как сказано в справке.
        HostApplicationBuilder builder = Host.CreateEmptyApplicationBuilder(new HostApplicationBuilderSettings
        {
            ContentRootPath = Directory.GetCurrentDirectory(),
        });

        builder.Configuration.AddEnvironmentVariables();

        // Без провайдеров: логи хоста не печатаются (адреса запросов).
        builder.Services.AddLogging();
        builder.Services.AddDomovoyCore(builder.Configuration);
        builder.Services.AddHomeAssistant();

        return builder.Build();
    }

    // ---------------------------------------------------------------- latency

    private static async Task<int> LatencyAsync(IHost host, LatencyArguments arguments, CancellationToken cancellationToken)
    {
        string[] phrases = (await File.ReadAllLinesAsync(arguments.PhrasesPath, cancellationToken).ConfigureAwait(false))
            .Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith('#'))
            .ToArray();

        HaConnectionState state = host.Services.GetRequiredService<HaConnectionState>();
        if (!await WaitForConnectedAsync(state, ConnectWait, cancellationToken).ConfigureAwait(false))
        {
            Print($"за {ConnectWait.TotalSeconds:F0} с соединение не установлено, статус {state.Status}");
            return 1;
        }

        Print("ha_websocket: Connected");

        IFastRouter router = host.Services.GetRequiredService<IFastRouter>();
        var reads = new List<string>();
        var actions = new List<string>();
        int unmatched = 0;
        int skippedActions = 0;

        foreach (string phrase in phrases)
        {
            FastRouteMatch? match = router.TryMatch(phrase);
            if (match is null)
            {
                unmatched++;
            }
            else if (string.Equals(match.Action, ReadAction, StringComparison.Ordinal))
            {
                reads.Add(phrase);
            }
            else if (arguments.AllowActions)
            {
                actions.Add(phrase);
            }
            else
            {
                skippedActions++;
            }
        }

        Print($"фраз: {phrases.Length}, чтение: {reads.Count}, действия: {actions.Count}, " +
              $"действий пропущено (нет --allow-actions): {skippedActions}, не разобрано шаблонами: {unmatched}");
        Print($"итераций на фразу: {arguments.Iterations}");

        PrintStatistics("чтение", await MeasureAsync(host, reads, arguments.Iterations, cancellationToken).ConfigureAwait(false));
        PrintStatistics("действия", await MeasureAsync(host, actions, arguments.Iterations, cancellationToken).ConfigureAwait(false));

        return 0;
    }

    private static async Task<Samples> MeasureAsync(
        IHost host,
        IReadOnlyList<string> phrases,
        int iterations,
        CancellationToken cancellationToken)
    {
        var samples = new Samples();

        for (int iteration = 0; iteration < iterations; iteration++)
        {
            foreach (string phrase in phrases)
            {
                // Новый экземпляр на запрос — как у api: IFastPath transient.
                IFastPath fastPath = host.Services.GetRequiredService<IFastPath>();

                long started = Stopwatch.GetTimestamp();
                FastPathOutcome outcome = await fastPath.TryHandleAsync(phrase, cancellationToken).ConfigureAwait(false);
                samples.Add(Stopwatch.GetElapsedTime(started), outcome);
            }
        }

        return samples;
    }

    private static void PrintStatistics(string label, Samples samples)
    {
        if (samples.Count == 0)
        {
            Print($"{label}: n=0");
            return;
        }

        Print(string.Create(
            CultureInfo.InvariantCulture,
            $"{label}: n={samples.Count}, совпавших={samples.Matched}, успешных={samples.Succeeded}, " +
            $"p50={samples.Percentile(0.50):F1} мс, p95={samples.Percentile(0.95):F1} мс, max={samples.Max:F1} мс"));

        if (samples.ErrorCodes.Count > 0)
        {
            Print($"{label}: коды отказов: " +
                  string.Join(", ", samples.ErrorCodes.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                      .Select(pair => $"{pair.Key}={pair.Value}")));
        }
    }

    // -------------------------------------------------------------- reconnect

    private static async Task<int> ReconnectAsync(IHost host, CancellationToken cancellationToken)
    {
        HaConnectionState state = host.Services.GetRequiredService<HaConnectionState>();
        HaStateCache cache = host.Services.GetRequiredService<HaStateCache>();
        IEntityAllowList allowList = host.Services.GetRequiredService<IEntityAllowList>();
        IHttpClientFactory clients = host.Services.GetRequiredService<IHttpClientFactory>();
        HaOptions options = host.Services.GetRequiredService<IOptions<HaOptions>>().Value;

        var rest = new RestWatch();
        Channel<DateTimeOffset> connected = Channel.CreateUnbounded<DateTimeOffset>();

        void OnStatusChanged(object? sender, HaConnectionStatus status)
        {
            Print($"ha_websocket: {status}");
            if (status == HaConnectionStatus.Connected)
            {
                connected.Writer.TryWrite(DateTimeOffset.Now);
            }
        }

        state.StatusChanged += OnStatusChanged;
        try
        {
            Print($"ha_websocket: {state.Status} (начальный)");
            if (state.Status == HaConnectionStatus.Connected)
            {
                connected.Writer.TryWrite(DateTimeOffset.Now);
            }

            Task polling = PollRestAsync(clients, options, rest, cancellationToken);

            await foreach (DateTimeOffset connectedAt in connected.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                if (rest.AnsweredSince is DateTimeOffset answeredAt && answeredAt <= connectedAt)
                {
                    Print(string.Create(
                        CultureInfo.InvariantCulture,
                        $"интервал «REST ответил → Connected»: {(connectedAt - answeredAt).TotalSeconds:F1} с"));
                }

                // Замер идёт после Connected, на уже поднявшемся HA: T здесь —
                // оценка снизу. Основной показатель — интервал выше.
                TimeSpan? getStates = await MeasureGetStatesAsync(options, cancellationToken).ConfigureAwait(false);
                Print(getStates is TimeSpan elapsed
                    ? string.Create(
                        CultureInfo.InvariantCulture,
                        $"время ответа get_states (после подъёма, HA прогрет; основной показатель — интервал «REST ответил → Connected»): {elapsed.TotalSeconds:F2} с")
                    : "время ответа get_states: не измерено (отдельная сессия не получила ответ)");

                await CompareAsync(cache, allowList, clients, options, cancellationToken).ConfigureAwait(false);
            }

            await polling.ConfigureAwait(false);
            return 0;
        }
        finally
        {
            state.StatusChanged -= OnStatusChanged;
        }
    }

    /// <summary>
    /// Опрос <c>GET api/</c> раз в секунду; печатается только смена
    /// доступности. HTTP-ответ — HTTP-сервер HA жив, кроме 502, 503 и 504
    /// (ответ прокси перед лежащим HA), как у воркера.
    /// </summary>
    private static async Task PollRestAsync(
        IHttpClientFactory clients,
        HaOptions options,
        RestWatch rest,
        CancellationToken cancellationToken)
    {
        bool? previous = null;

        while (!cancellationToken.IsCancellationRequested)
        {
            int? status = await RestStatusAsync(clients, options, cancellationToken).ConfigureAwait(false);
            bool answers = status is int code && code is not (502 or 503 or 504);

            if (answers != previous)
            {
                Print(answers
                    ? $"REST GET api/: отвечает (HTTP {status})"
                    : status is null ? "REST GET api/: не отвечает" : $"REST GET api/: не отвечает (HTTP {status}, ответ прокси)");
                rest.Set(answers);
                previous = answers;
            }

            await Task.Delay(RestPollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<int?> RestStatusAsync(IHttpClientFactory clients, HaOptions options, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RestPollTimeout);

        using HttpClient client = clients.CreateClient(HaWebSocketWorker.ProbeClientName);
        using var request = new HttpRequestMessage(HttpMethod.Get, "api/");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Token);

        try
        {
            using HttpResponseMessage response = await client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
            return (int)response.StatusCode;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
    }

    /// <summary>
    /// Время ответа <c>get_states</c> отдельной WebSocket-сессией: от
    /// отправки запроса до ответа. Слагаемое T бюджета восстановления.
    /// </summary>
    private static async Task<TimeSpan?> MeasureGetStatesAsync(HaOptions options, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(GetStatesWait);

        using var socket = new ClientWebSocket();
        try
        {
            await socket.ConnectAsync(HaWebSocketProtocol.BuildWebSocketUri(options.BaseUrl), deadline.Token).ConfigureAwait(false);

            if (await ReceiveTypeAsync(socket, deadline.Token).ConfigureAwait(false) != HaWebSocketProtocol.TypeAuthRequired)
            {
                return null;
            }

            await SendAsync(socket, HaWebSocketProtocol.Auth(options.Token!), deadline.Token).ConfigureAwait(false);
            if (await ReceiveTypeAsync(socket, deadline.Token).ConfigureAwait(false) != HaWebSocketProtocol.TypeAuthOk)
            {
                return null;
            }

            const int requestId = 1;
            long started = Stopwatch.GetTimestamp();
            await SendAsync(socket, HaWebSocketProtocol.GetStates(requestId), deadline.Token).ConfigureAwait(false);

            while (true)
            {
                using JsonDocument message = await ReceiveAsync(socket, deadline.Token).ConfigureAwait(false);
                JsonElement root = message.RootElement;
                if (HaWebSocketProtocol.GetString(root, "type") == HaWebSocketProtocol.TypeResult
                    && HaWebSocketProtocol.GetInt32(root, "id") == requestId)
                {
                    return Stopwatch.GetElapsedTime(started);
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception) when (exception is WebSocketException or JsonException or InvalidDataException)
        {
            return null;
        }
        finally
        {
            socket.Abort();
        }
    }

    /// <summary>
    /// Сверка кэша воркера с <c>GET api/states</c> по allow-list поэлементно:
    /// наличие, state и атрибуты. Именно Snapshot кэша, а не
    /// <see cref="IHaClient.GetStatesAsync"/>: тот вне Connected сам читает
    /// REST и сравнил бы REST с REST. Событие между двумя чтениями даёт
    /// ложное расхождение, поэтому сверка повторяется до трёх раз.
    /// </summary>
    private static async Task CompareAsync(
        HaStateCache cache,
        IEntityAllowList allowList,
        IHttpClientFactory clients,
        HaOptions options,
        CancellationToken cancellationToken)
    {
        int? differences = null;
        int compared = 0;

        for (int attempt = 1; attempt <= CompareAttempts; attempt++)
        {
            Dictionary<string, HaEntityState>? fromRest = await ReadRestStatesAsync(allowList, clients, options, cancellationToken)
                .ConfigureAwait(false);
            if (fromRest is null)
            {
                Print("сверка кэша: GET api/states не ответил");
                return;
            }

            Dictionary<string, HaEntityState> fromCache = cache.Snapshot()
                .ToDictionary(state => state.EntityId, StringComparer.Ordinal);

            compared = fromRest.Keys.Union(fromCache.Keys, StringComparer.Ordinal).Count();
            differences = fromRest.Keys.Union(fromCache.Keys, StringComparer.Ordinal).Count(entityId =>
                !fromRest.TryGetValue(entityId, out HaEntityState? expected)
                || !fromCache.TryGetValue(entityId, out HaEntityState? actual)
                || !SameState(expected, actual));

            if (differences == 0)
            {
                break;
            }

            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }

        Print($"сверка кэша с GET api/states: сущностей {compared}, расхождений: {differences}");
    }

    private static async Task<Dictionary<string, HaEntityState>?> ReadRestStatesAsync(
        IEntityAllowList allowList,
        IHttpClientFactory clients,
        HaOptions options,
        CancellationToken cancellationToken)
    {
        using HttpClient client = clients.CreateClient(HaServiceCollectionExtensions.HttpClientName);
        using var request = new HttpRequestMessage(HttpMethod.Get, "api/states");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Token);

        try
        {
            using HttpResponseMessage response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            using Stream body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using JsonDocument document = await JsonDocument.ParseAsync(body, cancellationToken: cancellationToken).ConfigureAwait(false);

            var states = new Dictionary<string, HaEntityState>(StringComparer.Ordinal);
            foreach (JsonElement element in document.RootElement.EnumerateArray())
            {
                HaEntityState state;
                try
                {
                    state = HaWebSocketProtocol.ParseState(element);
                }
                catch (JsonException)
                {
                    continue;
                }

                if (allowList.Find(state.EntityId) is not null)
                {
                    states[state.EntityId] = state;
                }
            }

            return states;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception) when (exception is HttpRequestException or JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    private static bool SameState(HaEntityState expected, HaEntityState actual) =>
        string.Equals(expected.State, actual.State, StringComparison.Ordinal)
        && expected.Attributes.Count == actual.Attributes.Count
        && expected.Attributes.All(pair =>
            actual.Attributes.TryGetValue(pair.Key, out string? value)
            && string.Equals(pair.Value, value, StringComparison.Ordinal));

    // ----------------------------------------------------------------- общее

    private static async Task<bool> WaitForConnectedAsync(
        HaConnectionState state,
        TimeSpan limit,
        CancellationToken cancellationToken)
    {
        var connected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        void OnStatusChanged(object? sender, HaConnectionStatus status)
        {
            if (status == HaConnectionStatus.Connected)
            {
                connected.TrySetResult();
            }
        }

        state.StatusChanged += OnStatusChanged;
        try
        {
            if (state.Status == HaConnectionStatus.Connected)
            {
                return true;
            }

            Task finished = await Task.WhenAny(connected.Task, Task.Delay(limit, cancellationToken)).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return finished == connected.Task;
        }
        finally
        {
            state.StatusChanged -= OnStatusChanged;
        }
    }

    private static async Task SendAsync(ClientWebSocket socket, byte[] message, CancellationToken cancellationToken) =>
        await socket.SendAsync(message, WebSocketMessageType.Text, endOfMessage: true, cancellationToken).ConfigureAwait(false);

    private static async Task<string?> ReceiveTypeAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        using JsonDocument message = await ReceiveAsync(socket, cancellationToken).ConfigureAwait(false);
        return HaWebSocketProtocol.GetString(message.RootElement, "type");
    }

    private static async Task<JsonDocument> ReceiveAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        byte[] buffer = new byte[16 * 1024];
        using var stream = new MemoryStream();

        while (true)
        {
            ValueWebSocketReceiveResult result = await socket.ReceiveAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                throw new WebSocketException(WebSocketError.ConnectionClosedPrematurely);
            }

            stream.Write(buffer, 0, result.Count);
            if (stream.Length > MaxMessageBytes)
            {
                throw new InvalidDataException("Сообщение больше допустимого.");
            }

            if (result.EndOfMessage)
            {
                return JsonDocument.Parse(stream.ToArray());
            }
        }
    }

    private static void Print(string line) =>
        Console.WriteLine($"{DateTimeOffset.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture)} {line}");

    /// <summary>Аргументы режима latency.</summary>
    private sealed record LatencyArguments(string PhrasesPath, int Iterations, bool AllowActions)
    {
        public static bool TryParse(string[] args, [NotNullWhen(true)] out LatencyArguments? parsed)
        {
            parsed = null;
            string? phrases = null;
            int iterations = 50;
            bool allowActions = false;

            for (int index = 0; index < args.Length; index++)
            {
                switch (args[index])
                {
                    case "--phrases" when index + 1 < args.Length:
                        phrases = args[++index];
                        break;
                    case "--iterations" when index + 1 < args.Length
                        && int.TryParse(args[index + 1], NumberStyles.None, CultureInfo.InvariantCulture, out int value)
                        && value > 0:
                        iterations = value;
                        index++;
                        break;
                    case "--allow-actions":
                        allowActions = true;
                        break;
                    default:
                        return false;
                }
            }

            if (phrases is null || !File.Exists(phrases))
            {
                return false;
            }

            parsed = new LatencyArguments(phrases, iterations, allowActions);
            return true;
        }
    }

    /// <summary>Замеры одной категории фраз.</summary>
    private sealed class Samples
    {
        private readonly List<double> _milliseconds = [];

        public int Count => _milliseconds.Count;

        public int Matched { get; private set; }

        public int Succeeded { get; private set; }

        public Dictionary<string, int> ErrorCodes { get; } = new(StringComparer.Ordinal);

        public double Max => _milliseconds.Max();

        public void Add(TimeSpan elapsed, FastPathOutcome outcome)
        {
            _milliseconds.Add(elapsed.TotalMilliseconds);

            if (outcome.Matched)
            {
                Matched++;
            }

            if (outcome.Result is { Success: true })
            {
                Succeeded++;
            }
            else if (outcome.Result?.ErrorCode is string code)
            {
                ErrorCodes[code] = ErrorCodes.GetValueOrDefault(code) + 1;
            }
        }

        /// <summary>Перцентиль по ближайшему рангу.</summary>
        public double Percentile(double fraction)
        {
            double[] sorted = [.. _milliseconds.Order()];
            int rank = (int)Math.Ceiling(fraction * sorted.Length);
            return sorted[Math.Clamp(rank, 1, sorted.Length) - 1];
        }
    }

    /// <summary>Момент, с которого REST отвечает без перерыва.</summary>
    private sealed class RestWatch
    {
        private readonly object _sync = new();
        private DateTimeOffset? _answeredSince;

        public DateTimeOffset? AnsweredSince
        {
            get
            {
                lock (_sync)
                {
                    return _answeredSince;
                }
            }
        }

        public void Set(bool answers)
        {
            lock (_sync)
            {
                _answeredSince = answers ? _answeredSince ?? DateTimeOffset.Now : null;
            }
        }
    }
}
