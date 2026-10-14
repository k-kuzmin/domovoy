using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing;

/// <summary>
/// Роутер быстрого пути (FR-CORE-2): нормализует фразу и перебирает
/// шаблоны в порядке регистрации, первый непустой результат — ответ.
///
/// Конкретных шаблонов роутер не знает: они приходят через
/// <see cref="IEnumerable{T}"/> из DI. Новый шаблон — один класс и одна
/// строка регистрации, роутер не меняется.
///
/// Allow-list здесь не проверяется: роутер только разрешает имя. Проверка
/// — одна точка на входе в слой Home Assistant.
/// </summary>
public sealed class FastRouter : IFastRouter
{
    private readonly IReadOnlyList<IFastRouteTemplate> _templates;
    private readonly IEntityAllowList _allowList;

    public FastRouter(IEnumerable<IFastRouteTemplate> templates, IEntityAllowList allowList)
    {
        ArgumentNullException.ThrowIfNull(templates);
        ArgumentNullException.ThrowIfNull(allowList);

        _templates = templates.ToList();
        _allowList = allowList;
    }

    public FastRouteMatch? TryMatch(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        string normalized = PhraseNormalizer.Normalize(text);
        if (normalized.Length == 0)
        {
            return null;
        }

        foreach (IFastRouteTemplate template in _templates)
        {
            FastRouteMatch? match = template.TryMatch(normalized, _allowList);
            if (match is not null)
            {
                return match;
            }
        }

        return null;
    }
}
