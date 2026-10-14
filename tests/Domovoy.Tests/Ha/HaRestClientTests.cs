using System.Globalization;
using System.Net;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.Registry;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using FluentAssertions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Tests.Ha;

/// <summary>
/// REST-клиент Home Assistant: единственная точка проверки allow-list для
/// действий (FR-HA-4, правила 5 и 6 раздела «Безопасность») и чтение
/// состояний — из кэша при актуальном соединении, иначе через REST.
/// </summary>
public sealed class HaRestClientTests : IAsyncLifetime, IDisposable
{
    private const string Token = "token-marker-7f3a";
    private const string AttributeMarker = "attribute-marker-9c1e";

    private const string KitchenLight = "light.example_kitchen_ceiling";
    private const string LivingRoomLight = "light.example_living_room_ceiling";
    private const string BedroomTemperature = "sensor.example_bedroom_temperature";
    private const string BedroomAc = "climate.example_bedroom_ac";
    private const string LivingRoomTv = "media_player.example_living_room_tv";
    private const string FrontDoor = "lock.example_front_door";
    private const string GuardedLight = "light.example_bedroom_guarded";
    private const string OutsideList = "light.example_not_in_list";

    private readonly TestAllowList _allowList = new();
    private readonly CapturingLoggerProvider _logs = new();
    private readonly HaConnectionState _connection = new();
    private FakeHomeAssistant _fake = null!;
    private HaStateCache _cache = null!;
    private HttpClient _http = null!;
    private ILoggerFactory _loggerFactory = null!;

    public async Task InitializeAsync()
    {
        _fake = await FakeHomeAssistant.StartAsync(Token);
        _cache = new HaStateCache(_allowList);
        _http = new HttpClient { BaseAddress = new Uri(_fake.BaseUrl + "/"), Timeout = TimeSpan.FromSeconds(10) };
        _loggerFactory = LoggerFactory.Create(builder => builder.SetMinimumLevel(LogLevel.Trace).AddProvider(_logs));
    }

    public async Task DisposeAsync() => await _fake.DisposeAsync();

    public void Dispose()
    {
        _http.Dispose();
        _loggerFactory.Dispose();
        _logs.Dispose();
    }

    [Fact(DisplayName = "При Connected состояния берутся из кэша, HA не спрашивается")]
    public async Task GetStatesBypassesCacheWhenNotConnectedAndReadsItWhenConnected()
    {
        _fake.SetState(KitchenLight, "off");
        _cache.ReplaceAll([State(KitchenLight, "on")]);
        _connection.Set(HaConnectionStatus.Connected);

        IReadOnlyList<HaEntityState> states = await CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        states.Should().ContainSingle().Which.State.Should().Be("on");
        _fake.RestRequests.Should().BeEmpty();
    }

    [Theory(DisplayName = "Вне Connected состояния читаются через REST с токеном")]
    [InlineData(nameof(HaConnectionStatus.Connecting))]
    [InlineData(nameof(HaConnectionStatus.Reconnecting))]
    [InlineData(nameof(HaConnectionStatus.AuthRejected))]
    public async Task GetStatesBypassesCacheWhenNotConnected(string status)
    {
        _fake.SetState(KitchenLight, "off", new Dictionary<string, object?> { ["brightness"] = 128 });
        _cache.ReplaceAll([State(KitchenLight, "on")]);
        _connection.Set(Enum.Parse<HaConnectionStatus>(status));

        IReadOnlyList<HaEntityState> states = await CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        HaEntityState state = states.Should().ContainSingle().Subject;
        state.State.Should().Be("off");
        state.Attributes.Should().Contain("brightness", "128");
        _fake.RestRequests.Should().ContainSingle().Which.Should().Match<FakeRestRequest>(
            request => request.Method == "GET" && request.Path == "/api/states" && request.AuthorizedWithExpectedToken);
    }

    [Fact(DisplayName = "Ответ REST фильтруется по allow-list")]
    public async Task GetStatesReturnsOnlyAllowListedEntities()
    {
        _fake.SetState(KitchenLight, "on");
        _fake.SetState(OutsideList, "on");
        _fake.SetState("switch.example_unknown", "off");

        IReadOnlyList<HaEntityState> states = await CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        states.Select(state => state.EntityId).Should().Equal(KitchenLight);
    }

    [Theory(DisplayName = "Фильтр по комнате и домену действует и на кэш, и на REST")]
    [InlineData(true)]
    [InlineData(false)]
    public async Task GetStatesReturnsOnlyAllowListedEntitiesOfAreaAndDomain(bool connected)
    {
        string[] ids = [KitchenLight, LivingRoomLight, BedroomTemperature, BedroomAc];
        foreach (string id in ids)
        {
            _fake.SetState(id, "on");
        }

        _cache.ReplaceAll(ids.Select(id => State(id, "on")));
        _connection.Set(connected ? HaConnectionStatus.Connected : HaConnectionStatus.Reconnecting);
        HaRestClient client = CreateClient();

        IReadOnlyList<HaEntityState> lights = await client.GetStatesAsync(null, "light", CancellationToken.None);
        IReadOnlyList<HaEntityState> bedroom = await client.GetStatesAsync("bedroom", null, CancellationToken.None);
        IReadOnlyList<HaEntityState> kitchenLights = await client.GetStatesAsync("kitchen", "light", CancellationToken.None);

        lights.Select(state => state.EntityId).Should().BeEquivalentTo([KitchenLight, LivingRoomLight]);
        bedroom.Select(state => state.EntityId).Should().BeEquivalentTo([BedroomTemperature, BedroomAc]);
        kitchenLights.Select(state => state.EntityId).Should().Equal(KitchenLight);
    }

    [Fact(DisplayName = "REST GET api/states не 2xx — HaUnavailableException")]
    public async Task GetStatesBypassesCacheWhenNotConnectedAndReportsNon2xx()
    {
        _fake.StatesStatusCode = HttpStatusCode.InternalServerError;

        Func<Task> act = () => CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        (await act.Should().ThrowAsync<HaUnavailableException>()).Which.Message.Should().NotContain(_fake.BaseUrl);
        AssertNothingSensitiveLogged();
    }

    [Fact(DisplayName = "REST недоступен — HaUnavailableException без адреса и токена")]
    public async Task GetStatesBypassesCacheWhenNotConnectedAndReportsNetworkError()
    {
        _fake.RestAvailable = false;

        Func<Task> act = () => CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        HaUnavailableException exception = (await act.Should().ThrowAsync<HaUnavailableException>()).Which;
        exception.Message.Should().NotContain(_fake.BaseUrl).And.NotContain(Token);
        exception.InnerException.Should().BeNull("текст сетевого исключения содержит адрес HA");
        AssertNothingSensitiveLogged();
    }

    [Fact(DisplayName = "Нечитаемый ответ REST — HaUnavailableException без исходного исключения")]
    public async Task GetStatesReportsMalformedResponseWithoutCause()
    {
        _fake.SetRawState(KitchenLight, $$"""{"entity_id":"{{KitchenLight}}","state":5}""");

        Func<Task> act = () => CreateClient().GetStatesAsync(null, null, CancellationToken.None);

        HaUnavailableException exception = (await act.Should().ThrowAsync<HaUnavailableException>()).Which;
        exception.InnerException.Should().BeNull("текст исключения разбора может цитировать ответ HA");
        AssertNothingSensitiveLogged();
    }

    [Fact(DisplayName = "Отмена вызывающей стороной пробрасывается, а не выдаётся за недоступность")]
    public async Task CallerCancellationPropagates()
    {
        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();

        Func<Task> act = () => CreateClient().GetStatesAsync(null, null, cancellation.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }

    [Fact(DisplayName = "Тело ответа HA и токен не попадают в лог")]
    public async Task ResponseBodyIsNotLogged()
    {
        _fake.SetState(KitchenLight, "on", new Dictionary<string, object?> { ["note"] = AttributeMarker });
        _fake.SetState(OutsideList, "on", new Dictionary<string, object?> { ["note"] = AttributeMarker });

        await CreateClient().GetStatesAsync(null, null, CancellationToken.None);
        await CreateClient().CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        AssertNothingSensitiveLogged();
    }

    [Fact(DisplayName = "Сущность вне allow-list — entity_not_allowed без запроса к HA")]
    public async Task CallServiceRejectsEntityOutsideAllowListWithoutCallingHa()
    {
        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", OutsideList, null, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.EntityNotAllowed);
    }

    [Theory(DisplayName = "Действие вне реестра или чужой домен — action_not_allowed без запроса к HA")]
    [InlineData("light", "set_brightness", BedroomAc, "22")]
    [InlineData("climate", "set_brightness", BedroomAc, "22")]
    [InlineData("media_player", "media_play", LivingRoomTv, null)]
    [InlineData("light", "turn_on", BedroomTemperature, null)]
    [InlineData("sensor", "turn_on", BedroomTemperature, null)]
    public async Task CallServiceRejectsDisallowedActionAndConfirmation(string domain, string action, string entityId, string? value)
    {
        ToolResult result = await CreateClient().CallServiceAsync(domain, action, entityId, value, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.ActionNotAllowed);
    }

    [Fact(DisplayName = "Действие read через вызов сервиса — action_not_allowed")]
    public async Task CallServiceRejectsDisallowedActionAndConfirmationForRead()
    {
        ToolResult result = await CreateClient().CallServiceAsync("sensor", "read", BedroomTemperature, null, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.ActionNotAllowed);
    }

    [Fact(DisplayName = "Действие в реестре, но вне каталога домена — action_not_allowed")]
    public async Task CallServiceRejectsDisallowedActionAndConfirmationOutsideCatalog()
    {
        ToolResult result = await CreateClient().CallServiceAsync("light", "self_destruct", KitchenLight, null, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.ActionNotAllowed);
    }

    [Theory(DisplayName = "Значение не проходит каталог — invalid_value без запроса к HA")]
    [InlineData(KitchenLight, "light", "set_brightness", "150")]
    [InlineData(KitchenLight, "light", "set_brightness", "сорок")]
    [InlineData(KitchenLight, "light", "set_brightness", null)]
    [InlineData(KitchenLight, "light", "turn_on", "1")]
    [InlineData(BedroomAc, "climate", "set_temperature", "40")]
    public async Task CallServiceRejectsInvalidValueWithoutCallingHa(string entityId, string domain, string action, string? value)
    {
        ToolResult result = await CreateClient().CallServiceAsync(domain, action, entityId, value, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.InvalidValue);
    }

    [Theory(DisplayName = "Замок требует подтверждения по каталогу, даже без флага реестра")]
    [InlineData("lock")]
    [InlineData("unlock")]
    public async Task LockActionRequiresConfirmationWithoutRegistryFlag(string action)
    {
        _allowList.Find(FrontDoor)!.RequiresConfirmation.Should().BeFalse();

        ToolResult result = await CreateClient().CallServiceAsync("lock", action, FrontDoor, null, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.ConfirmationRequired);
        result.RequiresConfirmation.Should().BeTrue();
    }

    [Fact(DisplayName = "Флаг реестра добавляет подтверждение действию, которому каталог его не требует")]
    public async Task CallServiceRejectsDisallowedActionAndConfirmationWhenRegistryFlagIsSet()
    {
        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", GuardedLight, null, CancellationToken.None);

        AssertRefused(result, HaErrorCodes.ConfirmationRequired);
        result.RequiresConfirmation.Should().BeTrue();
    }

    /// <summary>Каждое действие каталога, которому подтверждение не нужно.</summary>
    public static TheoryData<string, string> CatalogActionsWithoutConfirmation()
    {
        var data = new TheoryData<string, string>();
        foreach (KeyValuePair<string, IReadOnlyDictionary<string, HaActionSpec>> domain in
                 HaDomainCatalog.Actions.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            foreach (KeyValuePair<string, HaActionSpec> action in
                     domain.Value.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                if (!action.Value.RequiresConfirmation)
                {
                    data.Add(domain.Key, action.Key);
                }
            }
        }

        return data;
    }

    [Theory(DisplayName = "Каждое действие каталога без подтверждения уходит POST в сервис каталога")]
    [MemberData(nameof(CatalogActionsWithoutConfirmation))]
    public async Task CallServiceSendsMappedServiceForAllowedAction(string domain, string action)
    {
        HaActionSpec spec = HaDomainCatalog.Resolve(domain, action)!;
        string entityId = CatalogEntityId(domain);
        string? value = ValidValue(spec);

        ToolResult result = await CreateClient().CallServiceAsync(domain, action, entityId, value, CancellationToken.None);

        result.Success.Should().BeTrue(result.Error);
        result.ErrorCode.Should().BeNull();

        FakeRestRequest request = _fake.RestRequests.Should().ContainSingle().Subject;
        request.Method.Should().Be("POST");
        request.Path.Should().Be($"/api/services/{domain}/{spec.Service}");
        request.AuthorizedWithExpectedToken.Should().BeTrue();

        using JsonDocument body = JsonDocument.Parse(request.Body);
        body.RootElement.GetProperty("entity_id").GetString().Should().Be(entityId);
        if (spec.ValueField is null)
        {
            body.RootElement.EnumerateObject().Should().ContainSingle();
        }
        else
        {
            body.RootElement.GetProperty(spec.ValueField).ValueKind.Should().Be(spec.Kind switch
            {
                HaValueKind.Boolean => JsonValueKind.True,
                HaValueKind.String => JsonValueKind.String,
                _ => JsonValueKind.Number,
            });
        }
    }

    [Theory(DisplayName = "Разрешённое действие уходит POST в сервис каталога с типизированным телом")]
    [InlineData(KitchenLight, "light", "turn_off", null, "/api/services/light/turn_off", null)]
    [InlineData(KitchenLight, "light", "set_brightness", "40", "/api/services/light/turn_on", "brightness_pct")]
    [InlineData(BedroomAc, "climate", "set_temperature", "22,5", "/api/services/climate/set_temperature", "temperature")]
    [InlineData(LivingRoomTv, "media_player", "volume_set", "30", "/api/services/media_player/volume_set", "volume_level")]
    public async Task CallServiceSendsMappedServiceForAllowedActionWithTypedBody(
        string entityId,
        string domain,
        string action,
        string? value,
        string expectedPath,
        string? valueField)
    {
        ToolResult result = await CreateClient().CallServiceAsync(domain, action, entityId, value, CancellationToken.None);

        result.Success.Should().BeTrue();
        result.ErrorCode.Should().BeNull();
        result.ToolCallId.Should().Be(ToolResult.DirectCallId);

        FakeRestRequest request = _fake.RestRequests.Should().ContainSingle().Subject;
        request.Method.Should().Be("POST");
        request.Path.Should().Be(expectedPath);
        request.AuthorizedWithExpectedToken.Should().BeTrue();

        using JsonDocument body = JsonDocument.Parse(request.Body);
        body.RootElement.GetProperty("entity_id").GetString().Should().Be(entityId);
        if (valueField is null)
        {
            body.RootElement.EnumerateObject().Should().ContainSingle();
        }
        else
        {
            body.RootElement.GetProperty(valueField).ValueKind.Should().Be(JsonValueKind.Number);
        }
    }

    [Fact(DisplayName = "Процент громкости уходит дробью, яркость — целым")]
    public async Task ValuesAreTyped()
    {
        HaRestClient client = CreateClient();

        await client.CallServiceAsync("media_player", "volume_set", LivingRoomTv, "30", CancellationToken.None);
        await client.CallServiceAsync("light", "set_brightness", KitchenLight, "40", CancellationToken.None);

        FakeRestRequest[] requests = [.. _fake.RestRequests];
        JsonDocument.Parse(requests[0].Body).RootElement.GetProperty("volume_level").GetDecimal().Should().Be(0.3m);
        JsonDocument.Parse(requests[1].Body).RootElement.GetProperty("brightness_pct").GetRawText().Should().Be("40");
    }

    [Fact(DisplayName = "HA ответил не 2xx на вызов сервиса — ha_unavailable")]
    public async Task ServiceNon2xxIsUnavailable()
    {
        _fake.ServiceStatusCode = HttpStatusCode.InternalServerError;

        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        AssertUnavailable(result);
    }

    [Theory(DisplayName = "HA отклонил вызов сервиса (4xx) — ha_rejected, а не «недоступен»")]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.NotFound)]
    public async Task ServiceClientErrorIsRejected(HttpStatusCode status)
    {
        // Живой стек: media_player без поддержки turn_off — HA отвечает 400.
        _fake.ServiceStatusCode = status;

        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        result.Success.Should().BeFalse();
        result.ErrorCode.Should().Be(HaErrorCodes.HaRejected);
        result.ToolCallId.Should().Be(ToolResult.DirectCallId);
    }

    [Theory(DisplayName = "HA не принял токен при вызове сервиса — ha_unavailable")]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task ServiceAuthErrorIsUnavailable(HttpStatusCode status)
    {
        _fake.ServiceStatusCode = status;

        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        AssertUnavailable(result);
    }

    [Fact(DisplayName = "HA недоступен при вызове сервиса — ha_unavailable")]
    public async Task ServiceNetworkErrorIsUnavailable()
    {
        _fake.RestAvailable = false;

        ToolResult result = await CreateClient().CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        AssertUnavailable(result);
    }

    [Fact(DisplayName = "Токен не задан — HA не спрашивается: чтение и вызов отказывают как недоступность")]
    public async Task UnconfiguredTokenDoesNotCallHa()
    {
        HaRestClient client = CreateClient(token: null);

        Func<Task> read = () => client.GetStatesAsync(null, null, CancellationToken.None);
        ToolResult call = await client.CallServiceAsync("light", "turn_on", KitchenLight, null, CancellationToken.None);

        await read.Should().ThrowAsync<HaUnavailableException>();
        call.ErrorCode.Should().Be(HaErrorCodes.HaUnavailable);
        _fake.RestRequests.Should().BeEmpty();
    }

    private HaRestClient CreateClient(string? token = Token) => new(
        _http,
        _allowList,
        _cache,
        _connection,
        Options.Create(new HaOptions { BaseUrl = _fake.BaseUrl, Token = token }),
        _loggerFactory.CreateLogger<HaRestClient>());

    /// <summary>Сущность allow-list теста, которой разрешены все действия каталога домена.</summary>
    private static string CatalogEntityId(string domain) => $"{domain}.example_catalog";

    /// <summary>Значение, которое проходит описание действия: нижняя граница числа, true, короткая строка.</summary>
    private static string? ValidValue(HaActionSpec spec) => spec.Kind switch
    {
        HaValueKind.None => null,
        HaValueKind.Boolean => "true",
        HaValueKind.String => "HDMI 1",
        _ => spec.Min!.Value.ToString(CultureInfo.InvariantCulture),
    };

    private void AssertRefused(ToolResult result, string errorCode)
    {
        result.Success.Should().BeFalse();
        result.ErrorCode.Should().Be(errorCode);
        result.ToolCallId.Should().Be(ToolResult.DirectCallId);
        result.Error.Should().NotBeNullOrWhiteSpace();
        result.Error.Should().NotContain(_fake.BaseUrl).And.NotContain(Token);
        _fake.RestRequests.Should().BeEmpty("отказ проверки — до любого HTTP-запроса");
    }

    private void AssertUnavailable(ToolResult result)
    {
        result.Success.Should().BeFalse();
        result.ErrorCode.Should().Be(HaErrorCodes.HaUnavailable);
        result.ToolCallId.Should().Be(ToolResult.DirectCallId);
        result.Error.Should().NotBeNullOrWhiteSpace();
        result.Error.Should().NotContain(_fake.BaseUrl).And.NotContain(Token);
        AssertNothingSensitiveLogged();
    }

    private void AssertNothingSensitiveLogged()
    {
        string hostAndPort = new Uri(_fake.BaseUrl).Authority;

        _logs.EntriesContaining(Token).Should().BeEmpty();
        _logs.EntriesContaining(AttributeMarker).Should().BeEmpty();
        _logs.EntriesContaining(hostAndPort).Should().BeEmpty();
    }

    private static HaEntityState State(string entityId, string state) => new()
    {
        EntityId = entityId,
        State = state,
        Attributes = new Dictionary<string, string>(),
        LastChanged = DateTimeOffset.UnixEpoch,
        LastUpdated = DateTimeOffset.UnixEpoch,
    };

    /// <summary>
    /// Allow-list теста: у замка флаг реестра снят — подтверждение обязано
    /// прийти из каталога; у одного светильника флаг стоит — он подтверждение
    /// добавляет.
    /// </summary>
    private sealed class TestAllowList : IEntityAllowList
    {
        public IReadOnlyList<HaAreaDescriptor> Areas { get; } =
        [
            new() { Id = "kitchen", Name = "Кухня", Prepositional = "на кухне" },
            new() { Id = "living_room", Name = "Гостиная", Prepositional = "в гостиной" },
            new() { Id = "bedroom", Name = "Спальня", Prepositional = "в спальне" },
        ];

        public IReadOnlyList<HaEntityDescriptor> All { get; } =
        [
            Entity(KitchenLight, "kitchen", "turn_on", "turn_off", "toggle", "set_brightness", "self_destruct"),
            Entity(LivingRoomLight, "living_room", "turn_on", "turn_off"),
            Entity(BedroomTemperature, "bedroom", "read"),
            Entity(BedroomAc, "bedroom", "turn_on", "turn_off", "set_temperature"),
            Entity(LivingRoomTv, "living_room", "turn_off", "volume_set"),
            Entity(FrontDoor, "living_room", "lock", "unlock"),
            Entity(GuardedLight, "bedroom", "turn_on", "turn_off") with { RequiresConfirmation = true },
            .. HaDomainCatalog.Actions
                .Where(domain => domain.Value.Count > 0)
                .Select(domain => Entity(CatalogEntityId(domain.Key), "kitchen", [.. domain.Value.Keys])),
        ];

        public HaEntityDescriptor? Find(string entityId) =>
            All.FirstOrDefault(entity => string.Equals(entity.EntityId, entityId, StringComparison.Ordinal));

        public HaAreaDescriptor? FindArea(string areaId) =>
            Areas.FirstOrDefault(area => string.Equals(area.Id, areaId, StringComparison.Ordinal));

        public bool IsActionAllowed(string entityId, string action) =>
            Find(entityId)?.AllowedActions.Contains(action, StringComparer.Ordinal) ?? false;

        private static HaEntityDescriptor Entity(string entityId, string area, params string[] actions) => new()
        {
            EntityId = entityId,
            FriendlyName = entityId,
            Area = area,
            Domain = entityId[..entityId.IndexOf('.', StringComparison.Ordinal)],
            AllowedActions = actions,
        };
    }
}
