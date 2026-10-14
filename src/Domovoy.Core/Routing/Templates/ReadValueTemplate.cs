using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing.Templates;

/// <summary>
/// Чтение состояния: «какая температура в &lt;комната&gt;», «какая влажность
/// …», «сколько градусов …», «открыто ли окно …», «есть ли протечка …».
/// Сущность обязана разрешать действие <c>read</c>.
/// </summary>
internal sealed class ReadValueTemplate : IFastRouteTemplate
{
    private const string ReadAction = "read";

    private static readonly HashSet<string> Questions = new(StringComparer.Ordinal)
    {
        "какая",
        "какой",
        "какое",
    };

    private static readonly HashSet<string> OpenStates = new(StringComparer.Ordinal)
    {
        "открыто",
        "открыта",
        "открыт",
        "закрыто",
        "закрыта",
        "закрыт",
    };

    public string Name => "read_value";

    public FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList)
    {
        ArgumentNullException.ThrowIfNull(normalizedText);
        ArgumentNullException.ThrowIfNull(allowList);

        List<string>? device = DeviceTokens(EntityResolver.Tokenize(normalizedText));
        if (device is null)
        {
            return null;
        }

        HaEntityDescriptor? entity = EntityResolver.Resolve(
            device,
            allowList,
            candidate => EntityResolver.Allows(candidate, ReadAction),
            deviceRequired: true);

        return entity is null
            ? null
            : new FastRouteMatch { TemplateName = Name, EntityId = entity.EntityId, Action = ReadAction };
    }

    /// <summary>Слова устройства и комнаты после вопросительной конструкции или <c>null</c>.</summary>
    private static List<string>? DeviceTokens(List<string> tokens)
    {
        if (tokens.Count < 2)
        {
            return null;
        }

        // «какая температура в спальне»
        if (Questions.Contains(tokens[0]))
        {
            return tokens.GetRange(1, tokens.Count - 1);
        }

        if (tokens.Count < 3)
        {
            return null;
        }

        // «сколько градусов в спальне» — вопрос о температуре
        if (tokens[0] == "сколько" && tokens[1].StartsWith("градус", StringComparison.Ordinal))
        {
            return ["температура", .. tokens.GetRange(2, tokens.Count - 2)];
        }

        // «открыто ли окно на кухне», «есть ли протечка на кухне»
        if (tokens[1] == "ли" && (OpenStates.Contains(tokens[0]) || tokens[0] == "есть"))
        {
            return tokens.GetRange(2, tokens.Count - 2);
        }

        return null;
    }
}
