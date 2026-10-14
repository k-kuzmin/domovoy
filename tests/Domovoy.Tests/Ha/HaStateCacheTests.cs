using System.Globalization;
using System.Text.Json;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Domovoy.Ha.State;
using Domovoy.Ha.WebSocket;
using FluentAssertions;
using NSubstitute;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Кэш состояний (#9): фильтр allow-list на входе данных и порядок событий
/// одной сущности по <c>last_updated</c>.
/// </summary>
public sealed class HaStateCacheTests
{
    private const string Allowed = "light.example_kitchen";
    private const string AllowedSecond = "sensor.example_bedroom_temperature";
    private const string OffList = "light.example_off_list";

    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

    [Fact(DisplayName = "Сущность вне allow-list не попадает в кэш ни через ReplaceAll, ни через Apply")]
    public void CacheIgnoresEntitiesOutsideAllowList()
    {
        var cache = new HaStateCache(AllowList(Allowed));

        cache.ReplaceAll([State(Allowed, "on", T0), State(OffList, "on", T0)]);
        bool applied = cache.Apply(Change(State(OffList, "off", T0.AddSeconds(1))));

        applied.Should().BeFalse();
        cache.Find(OffList).Should().BeNull();
        cache.Snapshot().Select(state => state.EntityId).Should().Equal(Allowed);
    }

    [Fact(DisplayName = "ReplaceAll заменяет кэш целиком: исчезнувшая сущность удаляется")]
    public void ReplaceAllDropsVanishedEntities()
    {
        var cache = new HaStateCache(AllowList(Allowed, AllowedSecond));
        cache.ReplaceAll([State(Allowed, "on", T0), State(AllowedSecond, "21", T0)]);

        cache.ReplaceAll([State(Allowed, "off", T0.AddSeconds(5))]);

        cache.Find(AllowedSecond).Should().BeNull();
        cache.Find(Allowed)!.State.Should().Be("off");
        cache.Snapshot().Should().ContainSingle();
    }

    [Fact(DisplayName = "Событие строго старше записи отбрасывается, событие с равной меткой применяется")]
    public void StaleEventDoesNotOverwriteFresherState()
    {
        var cache = new HaStateCache(AllowList(Allowed));
        cache.ReplaceAll([State(Allowed, "on", T0)]);

        // Гонка «событие пришло до ответа get_states»: применяется после
        // ReplaceAll и не откатывает более свежее состояние.
        cache.Apply(Change(State(Allowed, "off", T0.AddMilliseconds(-1)))).Should().BeFalse();
        cache.Find(Allowed)!.State.Should().Be("on");

        cache.Apply(Change(State(Allowed, "off", T0))).Should().BeTrue();
        cache.Find(Allowed)!.State.Should().Be("off");
    }

    [Fact(DisplayName = "Событие только об атрибутах применяется по last_updated, а не last_changed")]
    public void AttributeOnlyEventIsApplied()
    {
        var cache = new HaStateCache(AllowList(Allowed));
        cache.ReplaceAll([State(Allowed, "on", T0, brightness: "100")]);

        HaEntityState attributeOnly = State(Allowed, "on", T0, brightness: "40") with
        {
            LastChanged = T0,
            LastUpdated = T0.AddSeconds(3),
        };

        cache.Apply(Change(attributeOnly)).Should().BeTrue();
        cache.Find(Allowed)!.Attributes["brightness"].Should().Be("40");
    }

    [Fact(DisplayName = "Событие о новой сущности из списка добавляет запись")]
    public void EventForUnseenAllowedEntityAddsRecord()
    {
        var cache = new HaStateCache(AllowList(Allowed));

        cache.Apply(Change(State(Allowed, "on", T0))).Should().BeTrue();

        cache.Find(Allowed)!.State.Should().Be("on");
    }

    [Fact(DisplayName = "Remove удаляет запись, а отсутствующую сущность молча пропускает")]
    public void RemoveDeletesRecordAndIgnoresMissing()
    {
        var cache = new HaStateCache(AllowList(Allowed, AllowedSecond));
        cache.ReplaceAll([State(Allowed, "on", T0), State(AllowedSecond, "21", T0)]);

        cache.Remove(Allowed);
        cache.Remove("light.example_never_seen");

        cache.Find(Allowed).Should().BeNull();
        cache.Snapshot().Select(state => state.EntityId).Should().Equal(AllowedSecond);
    }

    [Fact(DisplayName = "ParseState приводит атрибуты к строкам независимо от культуры потока")]
    public void StateAttributesAreConvertedToStrings()
    {
        const string json = """
            {
              "entity_id": "sensor.example_bedroom_temperature",
              "state": "21.5",
              "attributes": {
                "friendly_name": "Температура в спальне",
                "temperature": 21.5,
                "enabled": true,
                "nested": { "a": 1, "b": [1, 2] },
                "list": ["x", "y"],
                "missing": null
              },
              "last_changed": "2026-01-01T12:00:00.123456+00:00",
              "last_updated": "2026-01-01T12:00:05.5+00:00",
              "context": { "id": "c1", "parent_id": null, "user_id": null }
            }
            """;

        CultureInfo previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("ru-RU");
        HaEntityState state;
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            state = HaWebSocketProtocol.ParseState(document.RootElement);
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }

        state.EntityId.Should().Be("sensor.example_bedroom_temperature");
        state.State.Should().Be("21.5");
        state.Attributes.Should().BeEquivalentTo(new Dictionary<string, string>
        {
            ["friendly_name"] = "Температура в спальне",
            ["temperature"] = "21.5",
            ["enabled"] = "true",
            ["nested"] = """{ "a": 1, "b": [1, 2] }""",
            ["list"] = """["x", "y"]""",
        });
        state.Attributes.Should().NotContainKey("missing");
        state.LastChanged.Should().Be(new DateTimeOffset(2026, 1, 1, 12, 0, 0, TimeSpan.Zero).AddTicks(1234560));
        state.LastUpdated.Should().Be(new DateTimeOffset(2026, 1, 1, 12, 0, 5, 500, TimeSpan.Zero));
    }

    [Fact(DisplayName = "ParseState отказывает на объекте без обязательного поля")]
    public void ParseStateRejectsIncompleteObject()
    {
        using JsonDocument document = JsonDocument.Parse("""{ "entity_id": "light.example_kitchen" }""");
        JsonElement root = document.RootElement;

        Action act = () => HaWebSocketProtocol.ParseState(root);

        act.Should().Throw<JsonException>();
    }

    internal static IEntityAllowList AllowList(params string[] entityIds)
    {
        var descriptors = entityIds
            .Select(id => new HaEntityDescriptor
            {
                EntityId = id,
                FriendlyName = id,
                Area = "kitchen",
                Domain = id[..id.IndexOf('.', StringComparison.Ordinal)],
                AllowedActions = ["read"],
            })
            .ToDictionary(descriptor => descriptor.EntityId, StringComparer.Ordinal);

        IEntityAllowList allowList = Substitute.For<IEntityAllowList>();
        allowList.All.Returns(descriptors.Values.ToArray());
        allowList.Find(Arg.Any<string>()).Returns(call => descriptors.GetValueOrDefault(call.Arg<string>()));
        return allowList;
    }

    private static HaEntityState State(string entityId, string state, DateTimeOffset updated, string? brightness = null) =>
        new()
        {
            EntityId = entityId,
            State = state,
            Attributes = brightness is null
                ? new Dictionary<string, string>()
                : new Dictionary<string, string> { ["brightness"] = brightness },
            LastChanged = updated,
            LastUpdated = updated,
        };

    private static HaStateChange Change(HaEntityState current) =>
        new() { EntityId = current.EntityId, Current = current, OccurredAt = current.LastUpdated };
}
