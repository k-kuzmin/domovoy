namespace Domovoy.Core.Models;

/// <summary>
/// Совпадение фразы с шаблоном быстрого пути (FR-CORE-2): сущность из
/// allow-list и действие из её реестра.
/// </summary>
public sealed record FastRouteMatch
{
    /// <summary>Стабильное имя шаблона, давшего совпадение.</summary>
    public required string TemplateName { get; init; }

    public required string EntityId { get; init; }

    /// <summary>
    /// Имя действия из реестра сущности: <c>turn_on</c>, <c>read</c>,
    /// <c>set_temperature</c> … Не сервис HA.
    /// </summary>
    public required string Action { get; init; }

    /// <summary>
    /// Значение из фразы как есть или <c>null</c>. Тип и границы проверяет
    /// слой Home Assistant.
    /// </summary>
    public string? Value { get; init; }
}
