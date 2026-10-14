using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Шаблон быстрого пути (FR-CORE-2). Роутер перебирает шаблоны по порядку
/// регистрации и берёт первый непустой результат; новый шаблон добавляется
/// регистрацией, без правки роутера.
/// </summary>
public interface IFastRouteTemplate
{
    /// <summary>Стабильное имя шаблона.</summary>
    string Name { get; }

    /// <summary>
    /// Сопоставить фразу. <paramref name="normalizedText"/> — нижний
    /// регистр, «ё» заменена на «е», без знаков препинания, одиночные
    /// пробелы. <c>null</c> — шаблон не подошёл.
    /// </summary>
    FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList);
}
