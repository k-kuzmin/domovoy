namespace Domovoy.Core.Models;

/// <summary>
/// Комната из реестра сущностей (FR-HA-5). Падежи нужны шаблонам ответа и
/// разбору фраз: «включаю свет на кухне», «температура кухни».
/// </summary>
public sealed record HaAreaDescriptor
{
    /// <summary>Идентификатор комнаты, на который ссылается <see cref="HaEntityDescriptor.Area"/>.</summary>
    public required string Id { get; init; }

    /// <summary>Имя в именительном падеже: «Кухня».</summary>
    public required string Name { get; init; }

    /// <summary>Предложный падеж с предлогом: «на кухне», «в спальне».</summary>
    public required string Prepositional { get; init; }

    /// <summary>Родительный падеж: «кухни». <c>null</c>, если в реестре не задан.</summary>
    public string? Genitive { get; init; }
}
