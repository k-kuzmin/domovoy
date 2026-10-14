using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using FluentAssertions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.Ha;

/// <summary>
/// WebSocket-воркер против фейкового Home Assistant (#9): подписка, кэш,
/// живость соединения, пауза реконнекта и её досрочный конец.
///
/// Сроки <see cref="HaWebSocketTimings"/> — сотни миллисекунд вместо
/// секунд; пауза реконнекта подменена через <see cref="IReconnectDelay"/>.
/// Верхние границы времени даны с запасом <see cref="Slack"/>: классы
/// тестов идут параллельно, и машина CI бывает медленной. Нижние границы
/// по часам воркера — без запаса; по меткам сервера фейка — с допуском.
/// </summary>
public sealed class HaWebSocketWorkerTests
{
    private const string Kitchen = "light.example_kitchen";
    private const string Bedroom = "sensor.example_bedroom_temperature";
    private const string OffList = "light.example_off_list";

    private static readonly TimeSpan Slack = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan WaitLimit = TimeSpan.FromSeconds(15);

    private static readonly HaWebSocketTimings Fast = new()
    {
        HandshakeTimeout = TimeSpan.FromMilliseconds(1000),
        IdleBeforePing = TimeSpan.FromMilliseconds(500),
        PongTimeout = TimeSpan.FromMilliseconds(500),
        ReadinessPollInterval = TimeSpan.FromMilliseconds(150),
        ReadinessPollTimeout = TimeSpan.FromMilliseconds(150),
    };

    [Fact(DisplayName = "Воркер входит с токеном, подписывается на state_changed и наполняет кэш из get_states")]
    public async Task WorkerSubscribesToStateChangedAndPrimesCache()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetState(Bedroom, "21.5", new Dictionary<string, object?> { ["unit_of_measurement"] = "°C" });
            fake.SetState(OffList, "on");
        });

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Fake.LastAuthToken.Should().Be(harness.Token);
        harness.Fake.SubscribedEventTypes.Should().Equal("state_changed");
        harness.Fake.GetStatesCount.Should().Be(1);
        harness.Cache.Snapshot().Select(state => state.EntityId).Should().BeEquivalentTo([Kitchen, Bedroom]);
        harness.Cache.Find(Bedroom)!.State.Should().Be("21.5");
        harness.Cache.Find(Bedroom)!.Attributes["unit_of_measurement"].Should().Be("°C");
    }

    [Fact(DisplayName = "Чужая сущность в get_states отбрасывается до разбора: битое состояние не даёт предупреждения")]
    public async Task OffListStateIsDroppedBeforeParsing()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetRawState(OffList, $$"""{"entity_id":"{{OffList}}","state":5}""");
        });

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Cache.Snapshot().Select(state => state.EntityId).Should().Equal(Kitchen);
        harness.Logs.Entries.Should().NotContain(
            entry => entry.Level >= LogLevel.Warning,
            "объект сущности вне allow-list не разбирается вовсе");
    }

    [Fact(DisplayName = "Без токена воркер не подключается и ставит NotConfigured")]
    public async Task WorkerWithoutTokenStaysNotConfigured()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), token: string.Empty);

        await harness.WaitForStatusAsync(HaConnectionStatus.NotConfigured);
        await harness.Worker.ExecuteTask!.WaitAsync(WaitLimit);

        harness.Fake.WebSocketRequestCount.Should().Be(0);
    }

    [Fact(DisplayName = "Событие state_changed меняет кэш и приходит подписчику с Previous и Current")]
    public async Task WorkerAppliesStateChangedEventToCache()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake => fake.SetState(Kitchen, "on"));
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        await using Subscriber subscriber = harness.Subscribe();

        await harness.Fake.PushStateChangedAsync(Kitchen, "off");
        HaStateChange change = await subscriber.NextAsync();

        change.EntityId.Should().Be(Kitchen);
        change.Previous!.State.Should().Be("on");
        change.Current.State.Should().Be("off");
        harness.Cache.Find(Kitchen)!.State.Should().Be("off");
    }

    [Fact(DisplayName = "Событие о сущности вне allow-list подписчику не уходит")]
    public async Task OffListEventIsNotPublished()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetState(OffList, "on");
        });
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        await using Subscriber subscriber = harness.Subscribe();

        await harness.Fake.PushStateChangedAsync(OffList, "off");
        await harness.Fake.PushStateChangedAsync(Kitchen, "off");

        // События одного соединения приходят по порядку: опубликуй воркер
        // первое, подписчик получил бы его раньше второго.
        HaStateChange change = await subscriber.NextAsync();
        change.EntityId.Should().Be(Kitchen);
        harness.Cache.Find(OffList).Should().BeNull();
    }

    [Fact(DisplayName = "Событие с new_state = null удаляет сущность из кэша и подписчику не уходит")]
    public async Task WorkerRemovesEntityOnNullNewState()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetState(Bedroom, "21");
        });
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        await using Subscriber subscriber = harness.Subscribe();

        await harness.Fake.PushStateChangedAsync(Kitchen, state: null);
        await harness.Fake.PushStateChangedAsync(Bedroom, "22");
        HaStateChange control = await subscriber.NextAsync();

        control.EntityId.Should().Be(Bedroom);
        harness.Cache.Find(Kitchen).Should().BeNull();
        harness.Cache.Snapshot().Select(state => state.EntityId).Should().Equal(Bedroom);
        harness.State.Status.Should().Be(HaConnectionStatus.Connected);
    }

    [Fact(DisplayName = "Раннее удаление до ответа get_states не стирает сущность, которая в снимке новее")]
    public async Task EarlyRemovalDoesNotEraseFresherSnapshotEntity()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetState(Bedroom, "21");
            // Окно между запросом get_states и ответом — с запасом Slack: в
            // него должны уложиться событие и SetState на медленной машине CI.
            // Фейк отвечает на ping, ожидание дольше ping-окна попытку не рвёт.
            fake.GetStatesDelay = Slack;
        });

        // Подписка уже есть, ответ get_states ещё не ушёл: событие ляжет в
        // буфер ранних событий воркера.
        await WaitUntilAsync(() => harness.Fake.GetStatesCount >= 1, WaitLimit);
        await harness.Fake.PushStateChangedAsync(Kitchen, state: null);
        harness.State.Status.Should().NotBe(HaConnectionStatus.Connected, "событие должно прийти до ответа get_states");

        // Сущность вернулась без события, которое воркер увидит: снимок
        // get_states, собранный после задержки, несёт её с меткой новее удаления.
        harness.Fake.SetState(Kitchen, "off");

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Cache.Find(Kitchen).Should().NotBeNull("в снимке сущность новее раннего удаления");
        harness.Cache.Find(Kitchen)!.State.Should().Be("off");
        harness.Cache.Find(Bedroom).Should().NotBeNull();
    }

    [Fact(DisplayName = "Переполнение буфера ранних событий рвёт попытку, следующая перечитывает состояния; содержимое не логируется")]
    public async Task EarlyEventOverflowBreaksAttempt()
    {
        string marker = "light.example_marker_" + Guid.NewGuid().ToString("N");
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.GetStatesDelay = Slack;
        });

        await WaitUntilAsync(() => harness.Fake.GetStatesCount >= 1, WaitLimit);

        // Одним кадром-массивом: на предел больше, чем буфер вмещает.
        var frame = new System.Text.StringBuilder("[");
        for (int i = 0; i <= HaWebSocketWorker.MaxEarlyEvents; i++)
        {
            frame.Append(i == 0 ? string.Empty : ",")
                .Append("""{"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":""")
                .Append('"').Append(marker).Append("\"}}}");
        }

        await harness.Fake.PushRawAsync(frame.Append(']').ToString());
        harness.State.Status.Should().NotBe(HaConnectionStatus.Connected, "события должны прийти до ответа get_states");

        await WaitUntilAsync(() => harness.Fake.AuthCount >= 2, WaitLimit);
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Cache.Find(Kitchen).Should().NotBeNull("следующая попытка перечитала состояния целиком");
        harness.Logs.Entries.Should().Contain(entry => entry.Level == LogLevel.Warning && entry.Message.Contains("ранних событий"));
        harness.Logs.EntriesContaining(marker).Should().BeEmpty();
    }

    [Fact(DisplayName = "Нечитаемый кадр и незнакомый тип не роняют воркер, следующее событие применяется")]
    public async Task WorkerSurvivesMalformedMessages()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake => fake.SetState(Kitchen, "on"));
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        await using Subscriber subscriber = harness.Subscribe();

        await harness.Fake.PushRawAsync("{ это не json");
        await harness.Fake.PushRawAsync("""{"id":99,"type":"surprise"}""");
        await harness.Fake.PushRawAsync("""{"id":1,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"light.example_kitchen","new_state":{"broken":true}}}}""");
        await harness.Fake.PushStateChangedAsync(Kitchen, "off");

        HaStateChange change = await subscriber.NextAsync();
        change.Current.State.Should().Be("off");
        harness.Worker.ExecuteTask!.IsCompleted.Should().BeFalse();
        harness.Fake.AuthCount.Should().Be(1, "нечитаемый кадр — не повод переподключаться");
        harness.State.Status.Should().Be(HaConnectionStatus.Connected);
    }

    [Fact(DisplayName = "После переподключения кэш перечитывается целиком")]
    public async Task WorkerRereadsAllStatesAfterReconnect()
    {
        await using Harness harness = await Harness.StartAsync(Fast, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.SetState(Bedroom, "21");
        });
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Fake.WebSocketMode = FakeWebSocketMode.Down;
        harness.Fake.DropConnections();
        await harness.WaitForStatusAsync(HaConnectionStatus.Reconnecting);
        harness.Fake.SetState(Kitchen, "off");
        harness.Fake.RemoveState(Bedroom);
        harness.Fake.WebSocketMode = FakeWebSocketMode.Accept;

        await WaitUntilAsync(
            () => harness.Fake.GetStatesCount >= 2 && harness.State.Status == HaConnectionStatus.Connected,
            WaitLimit);

        harness.Cache.Snapshot()
            .ToDictionary(state => state.EntityId, state => state.State)
            .Should().BeEquivalentTo(harness.Fake.CurrentStates);
        harness.Cache.Find(Kitchen)!.State.Should().Be("off");
        harness.Cache.Find(Bedroom).Should().BeNull();
    }

    [Fact(DisplayName = "Пауза растёт 1, 2, 4 … до потолка, пока REST не отвечает, и сбрасывается после Connected")]
    public async Task WorkerReconnectsWithBackoffAndResetsAfterSuccess()
    {
        var delay = new RecordingDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake =>
            {
                fake.RestAvailable = false;
                fake.WebSocketMode = FakeWebSocketMode.Down;
            },
            maxDelaySeconds: 4);

        await WaitUntilAsync(() => delay.Recorded.Count >= 5, WaitLimit);
        delay.Recorded.Take(5).Should().Equal(Seconds(1, 2, 4, 4, 4));

        harness.Fake.WebSocketMode = FakeWebSocketMode.Accept;
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        int before = delay.Recorded.Count;

        harness.Fake.DropConnections();
        await WaitUntilAsync(() => delay.Recorded.Count > before, WaitLimit);

        delay.Recorded[before].Should().Be(TimeSpan.FromSeconds(1), "после Connected счёт попыток начинается заново");
        delay.Recorded.Should().OnlyContain(pause => pause <= TimeSpan.FromSeconds(4));
    }

    [Fact(DisplayName = "Замолчавшее соединение без ответа на ping считается оборванным")]
    public async Task WorkerTreatsSilentConnectionAsBreak()
    {
        var delay = new RecordingDelay();
        await using Harness harness = await Harness.StartAsync(Fast, delay, fake => fake.SetState(Kitchen, "on"));
        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        var silence = Stopwatch.StartNew();
        harness.Fake.SilentAfterAuth = true;
        harness.Fake.RespondToPing = false;

        await harness.WaitForTransitionAwayFromAsync(HaConnectionStatus.Connected);
        silence.Elapsed.Should().BeLessThan(Fast.IdleBeforePing + Fast.PongTimeout + Slack);

        await WaitUntilAsync(() => delay.Recorded.Count >= 1 && harness.Fake.AuthCount >= 2, WaitLimit);
        harness.Fake.PingCount.Should().BeGreaterThanOrEqualTo(1);
    }

    [Fact(DisplayName = "Подключение без auth_required обрывается по сроку рукопожатия")]
    public async Task WorkerAbortsHungHandshakeBeforeAuth()
    {
        var delay = new RecordingDelay();
        var started = Stopwatch.StartNew();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake => fake.WebSocketMode = FakeWebSocketMode.NoAuthRequired);

        await WaitUntilAsync(() => delay.Recorded.Count >= 1, WaitLimit);
        started.Elapsed.Should().BeLessThan(Fast.HandshakeTimeout + Slack);
        harness.State.Status.Should().NotBe(HaConnectionStatus.Connected);

        await WaitUntilAsync(() => harness.Fake.WebSocketRequestCount >= 2, WaitLimit);
        harness.Fake.AuthCount.Should().Be(0);
    }

    [Fact(DisplayName = "Молчание после auth_ok обрывается проверкой живости, а не висит на get_states")]
    public async Task WorkerAbortsHungHandshakeAfterAuth()
    {
        var delay = new RecordingDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake =>
            {
                fake.SilentAfterAuth = true;
                fake.RespondToPing = false;
            });

        await WaitUntilAsync(() => harness.Fake.AuthCount >= 1, WaitLimit);
        var afterAuth = Stopwatch.StartNew();

        await WaitUntilAsync(() => delay.Recorded.Count >= 1, WaitLimit);
        afterAuth.Elapsed.Should().BeLessThan(Fast.IdleBeforePing + Fast.PongTimeout + Slack);
        harness.State.Status.Should().NotBe(HaConnectionStatus.Connected);
        harness.Fake.PingCount.Should().BeGreaterThanOrEqualTo(1, "живость проверяется и во время ожидания get_states");

        await WaitUntilAsync(() => harness.Fake.AuthCount >= 2, WaitLimit);
    }

    [Fact(DisplayName = "После auth_invalid пауза идёт строго по расписанию, живой REST её не обрывает")]
    public async Task RejectedTokenPauseIgnoresLiveRest()
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake => fake.ExpectedToken = "other-token-" + Guid.NewGuid().ToString("N"));

        await harness.WaitForStatusAsync(HaConnectionStatus.AuthRejected);
        await WaitUntilAsync(() => delay.Started.Count >= 1, WaitLimit);

        await Task.Delay(3 * (Fast.ReadinessPollInterval + Fast.ReadinessPollTimeout));

        delay.Requested.Should().Equal(TimeSpan.FromSeconds(1));
        harness.Fake.AuthCount.Should().Be(1, "второй вход с отклонённым токеном до конца паузы HA может засчитать как неудачный вход");
        harness.Fake.ApiRootRequests.Should().BeEmpty("после auth_invalid REST не опрашивается");
        harness.State.Status.Should().Be(HaConnectionStatus.AuthRejected);
    }

    [Fact(DisplayName = "Поднявшийся HA обрывает паузу опросом REST")]
    public async Task PauseIsCutShortWhenHaComesBack()
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake =>
            {
                fake.RestAvailable = false;
                fake.WebSocketMode = FakeWebSocketMode.Down;
            });

        await WaitUntilAsync(() => delay.Started.Count >= 1, WaitLimit);

        var up = Stopwatch.StartNew();
        harness.Fake.RestAvailable = true;
        harness.Fake.WebSocketMode = FakeWebSocketMode.Accept;

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        up.Elapsed.Should().BeLessThan(
            Fast.ReadinessPollInterval + Fast.ReadinessPollTimeout + Fast.HandshakeTimeout + Slack);
    }

    [Theory(DisplayName = "Ответ прокси 502/503/504 при лежащем HA паузу не обрывает: попытки идут по расписанию")]
    [InlineData(HttpStatusCode.BadGateway)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    [InlineData(HttpStatusCode.GatewayTimeout)]
    public async Task GatewayErrorDoesNotCutPause(HttpStatusCode status)
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake =>
            {
                fake.ApiRootStatusCode = status;
                fake.WebSocketMode = FakeWebSocketMode.Down;
            });

        await WaitUntilAsync(() => delay.Started.Count >= 1, WaitLimit);

        // Опросы идут и получают ответ прокси, но пауза (бесконечная у
        // CancelOnlyDelay) не кончается: по расписанию попытка одна.
        await WaitUntilAsync(() => harness.Fake.ApiRootRequests.Count >= 3, WaitLimit);

        delay.Requested.Should().Equal(TimeSpan.FromSeconds(1));
        delay.Finished.Should().BeEmpty("ответ прокси — не готовность HA");
        harness.Fake.WebSocketRequestCount.Should().Be(1);
    }

    [Fact(DisplayName = "Ответ 401 на опрос — HA жив, пауза кончается")]
    public async Task UnauthorizedPollCutsPause()
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake =>
            {
                fake.ApiRootStatusCode = HttpStatusCode.Unauthorized;
                fake.WebSocketMode = FakeWebSocketMode.Down;
            });

        await WaitUntilAsync(() => delay.Finished.Count >= 1, WaitLimit);
        await WaitUntilAsync(() => harness.Fake.WebSocketRequestCount >= 2, WaitLimit);
    }

    [Fact(DisplayName = "При живом REST каждая пауза кончается первым опросом, опросы не чаще интервала")]
    public async Task PauseEndsAtFirstAnsweredPoll()
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake => fake.WebSocketMode = FakeWebSocketMode.RejectUpgrade);

        await WaitUntilAsync(() => delay.Finished.Count >= 3, WaitLimit);

        foreach (TimeSpan pause in delay.Finished.Take(3))
        {
            pause.Should().BeGreaterThanOrEqualTo(Fast.ReadinessPollInterval);
            pause.Should().BeLessThan(Fast.ReadinessPollInterval + Fast.ReadinessPollTimeout + Slack);
        }

        // Метки снимает сервер фейка. Первый запрос к нему платит за
        // холодный маршрут, поэтому первый зазор не сравнивается.
        IReadOnlyList<TimeSpan> polls = harness.Fake.ApiRootRequests;
        for (int i = 2; i < polls.Count; i++)
        {
            (polls[i] - polls[i - 1]).Should().BeGreaterThanOrEqualTo(
                Fast.ReadinessPollInterval * 0.8,
                "опросы не чаще интервала (с допуском на часы сервера)");
        }
    }

    [Fact(DisplayName = "REST поднялся раньше WebSocket: попытки идут чаще потолка, Connected укладывается в бюджет")]
    public async Task RestUpBeforeWebSocketStillConnectsWithinBudget()
    {
        var delay = new CancelOnlyDelay();
        await using Harness harness = await Harness.StartAsync(
            Fast,
            delay,
            fake => fake.WebSocketMode = FakeWebSocketMode.RejectUpgrade);

        // Окно отказа — 6 интервалов опроса; предел ожидания с запасом на
        // медленную машину. Без досрочного конца паузы попытка одна.
        await WaitUntilAsync(() => harness.Fake.WebSocketRequestCount >= 3, (6 * Fast.ReadinessPollInterval) + Slack);

        var ready = Stopwatch.StartNew();
        harness.Fake.WebSocketMode = FakeWebSocketMode.Accept;

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        ready.Elapsed.Should().BeLessThan(
            (2 * Fast.HandshakeTimeout) + Fast.ReadinessPollInterval + Fast.ReadinessPollTimeout + Slack);
    }

    [Fact(DisplayName = "Медленный get_states при живом сокете не рвёт попытку")]
    public async Task SlowGetStatesWithLiveSocketConnects()
    {
        HaWebSocketTimings timings = ProductionRatios();
        await using Harness harness = await Harness.StartAsync(timings, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.GetStatesDelay = 1.2 * timings.HandshakeTimeout;
        });

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Fake.AuthCount.Should().Be(1);
        harness.Fake.GetStatesCount.Should().Be(1);
        harness.Cache.Find(Kitchen).Should().NotBeNull();
    }

    [Fact(DisplayName = "get_states дольше ping-окна при отвечающем на ping HA не рвёт попытку")]
    public async Task SlowGetStatesLongerThanPingWindowConnects()
    {
        HaWebSocketTimings timings = ProductionRatios();
        await using Harness harness = await Harness.StartAsync(timings, new RecordingDelay(), fake =>
        {
            fake.SetState(Kitchen, "on");
            fake.GetStatesDelay = 1.2 * (timings.IdleBeforePing + timings.PongTimeout);
        });

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);

        harness.Fake.PingCount.Should().BeGreaterThanOrEqualTo(1);
        harness.Fake.AuthCount.Should().Be(1);
        harness.Fake.GetStatesCount.Should().Be(1);
    }

    [Fact(DisplayName = "Токен HA не попадает в лог: вход, отказ, обрыв, нечитаемый кадр")]
    public async Task HaTokenNeverAppearsInLogs()
    {
        string marker = "marker" + Guid.NewGuid().ToString("N");
        await using Harness harness = await Harness.StartAsync(
            Fast,
            new RecordingDelay(),
            fake => fake.SetState(Kitchen, "on"),
            token: marker);

        await harness.WaitForStatusAsync(HaConnectionStatus.Connected);
        await harness.Fake.PushRawAsync("{ нечитаемый кадр " + marker);
        await harness.Fake.PushStateChangedAsync(Kitchen, "off");
        await WaitUntilAsync(() => harness.Cache.Find(Kitchen)?.State == "off", WaitLimit);

        harness.Fake.ExpectedToken = "rotated-" + Guid.NewGuid().ToString("N");
        harness.Fake.DropConnections();
        await harness.WaitForStatusAsync(HaConnectionStatus.AuthRejected);

        harness.Logs.Entries.Should().NotBeEmpty("иначе проверка ничего не проверяет");
        harness.Logs.Entries.Should().Contain(entry => entry.Level >= LogLevel.Warning);
        harness.Logs.EntriesContaining(marker).Should().BeEmpty();
    }

    /// <summary>Боевые соотношения сроков (10 : 20 : 10 : 5 : 5 с) в масштабе 1 с = 50 мс.</summary>
    private static HaWebSocketTimings ProductionRatios() => new()
    {
        HandshakeTimeout = TimeSpan.FromMilliseconds(500),
        IdleBeforePing = TimeSpan.FromMilliseconds(1000),
        PongTimeout = TimeSpan.FromMilliseconds(500),
        ReadinessPollInterval = TimeSpan.FromMilliseconds(250),
        ReadinessPollTimeout = TimeSpan.FromMilliseconds(250),
    };

    private static TimeSpan[] Seconds(params int[] values) =>
        values.Select(value => TimeSpan.FromSeconds(value)).ToArray();

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan limit)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.Elapsed > limit)
            {
                throw new TimeoutException($"Условие не выполнилось за {limit.TotalSeconds} с.");
            }

            await Task.Delay(10);
        }
    }

    /// <summary>Записывает паузы и завершает их почти сразу.</summary>
    private sealed class RecordingDelay : IReconnectDelay
    {
        private readonly ConcurrentQueue<TimeSpan> _recorded = new();

        public IReadOnlyList<TimeSpan> Recorded => _recorded.ToArray();

        public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            _recorded.Enqueue(delay);
            return Task.Delay(TimeSpan.FromMilliseconds(10), cancellationToken);
        }
    }

    /// <summary>
    /// Пауза «бесконечна»: кончается только отменой. Записывает заказанную
    /// длительность, момент начала и фактическую длительность.
    /// </summary>
    private sealed class CancelOnlyDelay : IReconnectDelay
    {
        private readonly ConcurrentQueue<TimeSpan> _requested = new();
        private readonly ConcurrentQueue<long> _started = new();
        private readonly ConcurrentQueue<TimeSpan> _finished = new();

        public IReadOnlyList<TimeSpan> Requested => _requested.ToArray();

        public IReadOnlyList<long> Started => _started.ToArray();

        public IReadOnlyList<TimeSpan> Finished => _finished.ToArray();

        public async Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            _requested.Enqueue(delay);
            long started = Stopwatch.GetTimestamp();
            _started.Enqueue(started);
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            finally
            {
                _finished.Enqueue(Stopwatch.GetElapsedTime(started));
            }
        }
    }

    /// <summary>Фабрика клиентов без обработчиков: логи HTTP-клиента проверяет OutboundHttpLoggingTests.</summary>
    private sealed class PlainHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    /// <summary>Подписчик IHaEventSource, подписанный до толчка событий.</summary>
    private sealed class Subscriber : IAsyncDisposable
    {
        private readonly CancellationTokenSource _cts = new();
        private readonly IAsyncEnumerator<HaStateChange> _enumerator;

        public Subscriber(HaEventSource events) =>
            _enumerator = events.SubscribeAsync(_cts.Token).GetAsyncEnumerator();

        public async Task<HaStateChange> NextAsync()
        {
            bool moved = await _enumerator.MoveNextAsync().AsTask().WaitAsync(WaitLimit);
            moved.Should().BeTrue();
            return _enumerator.Current;
        }

        public async ValueTask DisposeAsync()
        {
            await _cts.CancelAsync();
            try
            {
                await _enumerator.DisposeAsync();
            }
            catch (OperationCanceledException)
            {
                // Перечисление, прерванное отменой.
            }

            _cts.Dispose();
        }
    }

    /// <summary>Фейк HA, воркер и его зависимости, собранные без хоста.</summary>
    private sealed class Harness : IAsyncDisposable
    {
        private readonly ConcurrentQueue<HaConnectionStatus> _transitions = new();
        private readonly ILoggerFactory _loggerFactory;

        private readonly HaWebSocketTimings _timings;
        private readonly IReconnectDelay _delay;
        private readonly int _maxDelaySeconds;

        private Harness(string token, HaWebSocketTimings timings, IReconnectDelay delay, int maxDelaySeconds)
        {
            Token = token;
            _timings = timings;
            _delay = delay;
            _maxDelaySeconds = maxDelaySeconds;
            Logs = new CapturingLoggerProvider();
            _loggerFactory = LoggerFactory.Create(builder => builder
                .SetMinimumLevel(LogLevel.Trace)
                .AddProvider(Logs));

            AllowList = HaStateCacheTests.AllowList(Kitchen, Bedroom);
            Cache = new HaStateCache(AllowList);
            State = new HaConnectionState();
            State.StatusChanged += (_, status) => _transitions.Enqueue(status);
            Events = new HaEventSource();
        }

        public FakeHomeAssistant Fake { get; private set; } = null!;

        public string Token { get; }

        public CapturingLoggerProvider Logs { get; }

        public IEntityAllowList AllowList { get; }

        public HaStateCache Cache { get; }

        public HaConnectionState State { get; }

        public HaEventSource Events { get; }

        public HaWebSocketWorker Worker { get; private set; } = null!;

        public static async Task<Harness> StartAsync(
            HaWebSocketTimings timings,
            IReconnectDelay delay,
            Action<FakeHomeAssistant>? arrange = null,
            string? token = null,
            int maxDelaySeconds = 60)
        {
            token ??= "token" + Guid.NewGuid().ToString("N");
            var harness = new Harness(token, timings, delay, maxDelaySeconds);
            try
            {
                await harness.InitializeAsync(arrange);
                return harness;
            }
            catch
            {
                await harness.DisposeAsync();
                throw;
            }
        }

        private async Task InitializeAsync(Action<FakeHomeAssistant>? arrange)
        {
            Fake = await FakeHomeAssistant.StartAsync(Token);
            arrange?.Invoke(Fake);

            var options = new HaOptions
            {
                BaseUrl = Fake.BaseUrl,
                Token = Token,
                ReconnectMaxDelaySeconds = _maxDelaySeconds,
            };

            Worker = new HaWebSocketWorker(
                Options.Create(options),
                AllowList,
                Cache,
                State,
                Events,
                _delay,
                _timings,
                new PlainHttpClientFactory(),
                _loggerFactory.CreateLogger<HaWebSocketWorker>());
            await Worker.StartAsync(CancellationToken.None);
        }

        public Subscriber Subscribe() => new(Events);

        public Task WaitForStatusAsync(HaConnectionStatus status) =>
            WaitUntilAsync(() => State.Status == status, WaitLimit);

        /// <summary>Ждать первого перехода из статуса — по журналу переходов, а не опросом: переход бывает коротким.</summary>
        public async Task WaitForTransitionAwayFromAsync(HaConnectionStatus status)
        {
            int seen = _transitions.Count;
            await WaitUntilAsync(() => _transitions.Skip(seen).Any(next => next != status), WaitLimit);
        }

        public async ValueTask DisposeAsync()
        {
            if (Worker is not null)
            {
                using (var stop = new CancellationTokenSource(WaitLimit))
                {
                    await Worker.StopAsync(stop.Token);
                }

                Worker.Dispose();
            }

            if (Fake is not null)
            {
                await Fake.DisposeAsync();
            }

            _loggerFactory.Dispose();
            Logs.Dispose();
        }
    }
}
