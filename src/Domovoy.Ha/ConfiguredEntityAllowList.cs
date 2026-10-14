using System.Collections.Frozen;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;
using Domovoy.Ha.Registry;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// Allow-list сущностей из реестра (FR-HA-4, FR-HA-5).
///
/// Реестр проверен <see cref="EntityRegistryValidator"/> до того, как сюда
/// попадает: <see cref="IOptions{TOptions}.Value"/> не отдаёт реестр, не
/// прошедший проверку. Пустой реестр — пустой список: он запрещает всё, а
/// не разрешает. Сравнение entity_id и действий — порядковое, без поправок
/// на регистр: «Light.X» и «light.x» — разные сущности.
/// </summary>
internal sealed class ConfiguredEntityAllowList : IEntityAllowList
{
    private readonly FrozenDictionary<string, HaEntityDescriptor> _entities;
    private readonly FrozenDictionary<string, HaAreaDescriptor> _areas;

    public ConfiguredEntityAllowList(IOptions<EntityRegistryOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);

        EntityRegistryOptions registry = options.Value;

        All = registry.Entities
            .OfType<EntityEntry>()
            .Select(entry => new HaEntityDescriptor
            {
                EntityId = entry.EntityId!,
                FriendlyName = entry.Name!,
                Area = entry.Area!,
                Domain = entry.Domain!,
                AllowedActions = entry.Actions!.OfType<string>().ToArray(),
                RequiresConfirmation = entry.RequiresConfirmation,
            })
            .ToArray();

        Areas = registry.Areas
            .OfType<AreaEntry>()
            .Select(entry => new HaAreaDescriptor
            {
                Id = entry.Id!,
                Name = entry.Name!,
                Prepositional = entry.Cases!.Prepositional!,
                Genitive = entry.Cases.Genitive,
            })
            .ToArray();

        _entities = All.ToFrozenDictionary(entity => entity.EntityId, StringComparer.Ordinal);
        _areas = Areas.ToFrozenDictionary(area => area.Id, StringComparer.Ordinal);
    }

    public IReadOnlyList<HaEntityDescriptor> All { get; }

    public IReadOnlyList<HaAreaDescriptor> Areas { get; }

    public bool IsActionAllowed(string entityId, string action) =>
        Find(entityId) is HaEntityDescriptor entity
        && entity.AllowedActions.Contains(action, StringComparer.Ordinal);

    public HaEntityDescriptor? Find(string entityId) =>
        _entities.GetValueOrDefault(entityId);

    public HaAreaDescriptor? FindArea(string areaId) =>
        _areas.GetValueOrDefault(areaId);
}
