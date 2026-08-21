namespace Domovoy.Core.Models;

/// <summary>
/// Описание сущности из allow-list (FR-HA-4, FR-HA-5). Сущность, не
/// попавшая в список, невидима для LLM и не может быть изменена.
/// </summary>
public sealed record HaEntityDescriptor
{
    /// <summary>Идентификатор сущности в Home Assistant, например <c>light.example_room</c>.</summary>
    public required string EntityId { get; init; }

    /// <summary>Человекочитаемое имя для промпта и шаблонов ответа.</summary>
    public required string FriendlyName { get; init; }

    /// <summary>Комната.</summary>
    public required string Area { get; init; }

    /// <summary>Домен Home Assistant: <c>light</c>, <c>switch</c>, <c>sensor</c>.</summary>
    public required string Domain { get; init; }

    /// <summary>
    /// Допустимые действия. Белый список: всё, чего здесь нет, не будет
    /// вызвано, даже если LLM это предложит.
    /// </summary>
    public required IReadOnlyList<string> AllowedActions { get; init; }

    /// <summary>
    /// Действие требует подтверждения вторым сообщением: замки,
    /// сигнализация, ворота, газ.
    /// </summary>
    public bool RequiresConfirmation { get; init; }
}
