using System.Text.RegularExpressions;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing.Templates;

/// <summary>
/// Установка значения: «поставь 22 градуса в спальне», «сделай свет на
/// кухне на 40 процентов», «убавь свет в гостиной до 30 процентов».
///
/// Единица после числа выбирает действие: градусы — <c>set_temperature</c>,
/// проценты — <c>set_brightness</c>. Число уходит как есть, тип и границы
/// проверяет слой Home Assistant. Относительное изменение («убавь на 10
/// процентов») шаблон не разбирает: у глаголов изменения допустим только
/// предлог «до».
/// </summary>
internal sealed partial class SetValueTemplate : IFastRouteTemplate
{
    private static readonly HashSet<string> AbsoluteVerbs = new(StringComparer.Ordinal)
    {
        "поставь",
        "установи",
        "выстави",
        "сделай",
    };

    private static readonly HashSet<string> RelativeVerbs = new(StringComparer.Ordinal)
    {
        "убавь",
        "прибавь",
        "уменьши",
        "увеличь",
    };

    private static readonly Unit[] Units =
    [
        new("градус", "set_temperature", ["температуру", "температура", "температуры"]),
        new("процент", "set_brightness", ["яркость", "яркости"]),
    ];

    public string Name => "set_value";

    public FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList)
    {
        ArgumentNullException.ThrowIfNull(normalizedText);
        ArgumentNullException.ThrowIfNull(allowList);

        List<string> tokens = EntityResolver.Tokenize(normalizedText);
        if (tokens.Count < 3)
        {
            return null;
        }

        bool relative = RelativeVerbs.Contains(tokens[0]);
        if (!relative && !AbsoluteVerbs.Contains(tokens[0]))
        {
            return null;
        }

        var numbers = tokens.Select((token, index) => (token, index)).Where(item => Number().IsMatch(item.token)).ToList();
        if (numbers.Count != 1 || numbers[0].index + 1 >= tokens.Count)
        {
            return null;
        }

        int numberIndex = numbers[0].index;
        Unit? unit = Array.Find(Units, candidate => tokens[numberIndex + 1].StartsWith(candidate.Stem, StringComparison.Ordinal));
        if (unit is null)
        {
            return null;
        }

        string? preposition = numberIndex > 1 ? tokens[numberIndex - 1] : null;
        bool hasPreposition = preposition is "на" or "до";
        if (relative && preposition != "до")
        {
            return null;
        }

        int removeFrom = hasPreposition ? numberIndex - 1 : numberIndex;
        var rest = tokens
            .Where((_, index) => index != 0 && (index < removeFrom || index > numberIndex + 1))
            .Where(token => !unit.PropertyWords.Contains(token, StringComparer.Ordinal))
            .ToList();

        HaEntityDescriptor? entity = EntityResolver.Resolve(
            rest,
            allowList,
            candidate => EntityResolver.Allows(candidate, unit.Action),
            deviceRequired: false);

        return entity is null
            ? null
            : new FastRouteMatch
            {
                TemplateName = Name,
                EntityId = entity.EntityId,
                Action = unit.Action,
                Value = tokens[numberIndex],
            };
    }

    [GeneratedRegex(@"^\d+([.,]\d+)?$", RegexOptions.CultureInvariant)]
    private static partial Regex Number();

    private sealed record Unit(string Stem, string Action, string[] PropertyWords);
}
