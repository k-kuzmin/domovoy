using Microsoft.Extensions.Options;

namespace Domovoy.Ha.Registry;

/// <summary>
/// Проверка реестра сущностей на старте (ValidateOnStart): реестр, который
/// не проходит проверку, не запускает сервис. Allow-list с дырой хуже
/// отказа старта — дыру никто не заметит.
///
/// Каждое сообщение называет запись номером в разделе (<c>entities[3]</c>) и
/// поле. Значений из реестра — entity_id, id комнаты, script_id, area — в
/// сообщении нет: оно уходит в лог старта, а реестр — приватный профиль дома.
/// Домен и действие цитируются: это словарь Home Assistant, а не данные дома,
/// хотя в отказе «не входит в каталог» значение берётся из файла как есть.
/// </summary>
internal sealed class EntityRegistryValidator : IValidateOptions<EntityRegistryOptions>
{
    public ValidateOptionsResult Validate(string? name, EntityRegistryOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (options.LoadError is not null)
        {
            return ValidateOptionsResult.Fail(options.LoadError);
        }

        var failures = new List<string>();

        HashSet<string> areaIds = ValidateAreas(options.Areas, failures);
        ValidateEntities(options.Entities, areaIds, failures);
        ValidateScripts(options.Scripts, failures);

        return failures.Count == 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail(failures);
    }

    private static HashSet<string> ValidateAreas(List<AreaEntry?> areas, List<string> failures)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);

        for (int index = 0; index < areas.Count; index++)
        {
            AreaEntry? area = areas[index];

            if (area is null)
            {
                failures.Add($"areas[{index}]: пустая запись комнаты.");
                continue;
            }

            string label = $"areas[{index}]";

            if (IsBlank(area.Id))
            {
                failures.Add($"{label}: не задано поле id.");
            }
            else if (!ids.Add(area.Id!))
            {
                failures.Add($"{label}: повтор поля id.");
            }

            if (IsBlank(area.Name))
            {
                failures.Add($"{label}: не задано поле name.");
            }

            if (IsBlank(area.Cases?.Prepositional))
            {
                failures.Add($"{label}: не задано поле cases.prepositional.");
            }
        }

        return ids;
    }

    private static void ValidateEntities(List<EntityEntry?> entities, HashSet<string> areaIds, List<string> failures)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);

        for (int index = 0; index < entities.Count; index++)
        {
            EntityEntry? entity = entities[index];

            if (entity is null)
            {
                failures.Add($"entities[{index}]: пустая запись сущности.");
                continue;
            }

            string label = $"entities[{index}]";

            if (IsBlank(entity.EntityId))
            {
                failures.Add($"{label}: не задано поле entity_id.");
            }
            else if (!ids.Add(entity.EntityId!))
            {
                failures.Add($"{label}: повтор поля entity_id.");
            }

            if (IsBlank(entity.Name))
            {
                failures.Add($"{label}: не задано поле name.");
            }

            if (IsBlank(entity.Area))
            {
                failures.Add($"{label}: не задано поле area.");
            }
            else if (!areaIds.Contains(entity.Area!))
            {
                failures.Add($"{label}: поле area — такой комнаты нет в areas.");
            }

            if (entity.Actions is null || entity.Actions.Count == 0)
            {
                failures.Add($"{label}: не задано поле actions.");
            }

            if (IsBlank(entity.Domain))
            {
                failures.Add($"{label}: не задано поле domain.");
                continue;
            }

            string domain = entity.Domain!;

            if (!HaDomainCatalog.IsKnownDomain(domain))
            {
                failures.Add($"{label}: поле domain — домен «{domain}» не входит в каталог слоя Home Assistant.");
                continue;
            }

            if (!IsBlank(entity.EntityId)
                && !(entity.EntityId!.StartsWith(domain + ".", StringComparison.Ordinal)
                     && entity.EntityId.Length > domain.Length + 1))
            {
                failures.Add($"{label}: поле entity_id — префикс не совпадает с domain «{domain}».");
            }

            foreach (string? action in entity.Actions ?? [])
            {
                if (IsBlank(action))
                {
                    failures.Add($"{label}: поле actions — пустое действие.");
                }
                else if (!HaDomainCatalog.IsActionAllowed(domain, action!))
                {
                    failures.Add($"{label}: поле actions — действие «{action}» не входит в домен «{domain}».");
                }
            }
        }
    }

    private static void ValidateScripts(List<ScriptEntry?> scripts, List<string> failures)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);

        for (int index = 0; index < scripts.Count; index++)
        {
            ScriptEntry? script = scripts[index];

            if (script is null)
            {
                failures.Add($"scripts[{index}]: пустая запись сценария.");
                continue;
            }

            string label = $"scripts[{index}]";

            if (IsBlank(script.ScriptId))
            {
                failures.Add($"{label}: не задано поле script_id.");
            }
            else if (!ids.Add(script.ScriptId!))
            {
                failures.Add($"{label}: повтор поля script_id.");
            }

            if (IsBlank(script.Name))
            {
                failures.Add($"{label}: не задано поле name.");
            }
        }
    }

    private static bool IsBlank(string? value) => string.IsNullOrWhiteSpace(value);
}
