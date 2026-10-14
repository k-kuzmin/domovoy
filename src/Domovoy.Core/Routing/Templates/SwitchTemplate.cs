using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing.Templates;

/// <summary>
/// «Включи/выключи &lt;устройство&gt; &lt;комната&gt;» и синонимы глагола:
/// зажги, погаси, отключи, вруби, выруби, переключи.
///
/// Домены — только свет и климат: фразы о медиа и пылесосе в этот шаблон не
/// входят и уходят на путь через LLM, даже если у сущности есть
/// <c>turn_off</c>.
/// </summary>
internal sealed class SwitchTemplate : IFastRouteTemplate
{
    private static readonly Dictionary<string, string> Verbs = new(StringComparer.Ordinal)
    {
        ["включи"] = "turn_on",
        ["включить"] = "turn_on",
        ["зажги"] = "turn_on",
        ["вруби"] = "turn_on",
        ["выключи"] = "turn_off",
        ["выключить"] = "turn_off",
        ["погаси"] = "turn_off",
        ["отключи"] = "turn_off",
        ["выруби"] = "turn_off",
        ["переключи"] = "toggle",
    };

    private static readonly HashSet<string> Domains = new(StringComparer.Ordinal) { "light", "climate" };

    public string Name => "switch";

    public FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList)
    {
        ArgumentNullException.ThrowIfNull(normalizedText);
        ArgumentNullException.ThrowIfNull(allowList);

        List<string> tokens = EntityResolver.Tokenize(normalizedText);
        if (tokens.Count < 2 || !Verbs.TryGetValue(tokens[0], out string? action))
        {
            return null;
        }

        HaEntityDescriptor? entity = EntityResolver.Resolve(
            tokens.GetRange(1, tokens.Count - 1),
            allowList,
            candidate => Domains.Contains(candidate.Domain) && EntityResolver.Allows(candidate, action),
            deviceRequired: true);

        return entity is null
            ? null
            : new FastRouteMatch { TemplateName = Name, EntityId = entity.EntityId, Action = action };
    }
}
