using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Tests.Routing;

/// <summary>
/// Тестовый allow-list: та же вымышленная квартира, что в
/// <c>config/entities.example.yaml</c>, — те же комнаты, сущности, домены
/// и действия. Реальных <c>entity_id</c> здесь нет и быть не может.
/// </summary>
internal sealed class ExampleApartment : IEntityAllowList
{
    public IReadOnlyList<HaAreaDescriptor> Areas { get; } =
    [
        new() { Id = "kitchen", Name = "Кухня", Prepositional = "на кухне", Genitive = "кухни" },
        new() { Id = "living_room", Name = "Гостиная", Prepositional = "в гостиной", Genitive = "гостиной" },
        new() { Id = "bedroom", Name = "Спальня", Prepositional = "в спальне", Genitive = "спальни" },
    ];

    public IReadOnlyList<HaEntityDescriptor> All { get; } =
    [
        Entity("light.example_kitchen_ceiling", "Свет на кухне", "kitchen", "turn_on", "turn_off", "toggle", "set_brightness"),
        Entity("light.example_living_room_ceiling", "Свет в гостиной", "living_room", "turn_on", "turn_off", "toggle", "set_brightness"),
        Entity(
            "media_player.example_living_room_tv",
            "Телевизор",
            "living_room",
            "turn_off",
            "volume_set",
            "volume_up",
            "volume_down",
            "volume_mute",
            "select_source"),
        Entity(
            "media_player.example_bedroom_speaker",
            "Колонка в спальне",
            "bedroom",
            "media_play",
            "media_pause",
            "media_next_track",
            "media_previous_track",
            "volume_set",
            "volume_mute"),
        Entity("vacuum.example_living_room_robot", "Робот-пылесос", "living_room", "start", "pause", "return_to_base", "locate"),
        Entity("sensor.example_bedroom_temperature", "Температура в спальне", "bedroom", "read"),
        Entity("sensor.example_bedroom_humidity", "Влажность в спальне", "bedroom", "read"),
        Entity("binary_sensor.example_kitchen_window", "Окно на кухне", "kitchen", "read"),
        Entity("binary_sensor.example_kitchen_leak", "Датчик протечки на кухне", "kitchen", "read"),
        Entity("climate.example_bedroom_ac", "Кондиционер в спальне", "bedroom", "turn_on", "turn_off", "set_temperature"),
        Entity("climate.example_kitchen_boiler_thermostat", "Терморегулятор котла", "kitchen", "read"),
        Entity("lock.example_front_door", "Входная дверь", "living_room", "lock", "unlock") with { RequiresConfirmation = true },
    ];

    public HaEntityDescriptor? Find(string entityId) =>
        All.FirstOrDefault(entity => string.Equals(entity.EntityId, entityId, StringComparison.Ordinal));

    public HaAreaDescriptor? FindArea(string areaId) =>
        Areas.FirstOrDefault(area => string.Equals(area.Id, areaId, StringComparison.Ordinal));

    public bool IsActionAllowed(string entityId, string action) =>
        Find(entityId)?.AllowedActions.Contains(action, StringComparer.Ordinal) ?? false;

    private static HaEntityDescriptor Entity(string entityId, string name, string area, params string[] actions) => new()
    {
        EntityId = entityId,
        FriendlyName = name,
        Area = area,
        Domain = entityId[..entityId.IndexOf('.', StringComparison.Ordinal)],
        AllowedActions = actions,
    };
}
