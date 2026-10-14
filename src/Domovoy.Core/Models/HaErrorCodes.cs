namespace Domovoy.Core.Models;

/// <summary>
/// Коды отказа слоя Home Assistant: <see cref="ToolResult.ErrorCode"/> и
/// <see cref="ApiError.Code"/> используют одни и те же строки.
/// </summary>
public static class HaErrorCodes
{
    /// <summary>Сущности нет в allow-list (FR-HA-4).</summary>
    public const string EntityNotAllowed = "entity_not_allowed";

    /// <summary>Действие не разрешено сущности или не входит в каталог домена.</summary>
    public const string ActionNotAllowed = "action_not_allowed";

    /// <summary>Значение отсутствует, лишнее, не того типа или вне границ.</summary>
    public const string InvalidValue = "invalid_value";

    /// <summary>Действие требует подтверждения вторым сообщением.</summary>
    public const string ConfirmationRequired = "confirmation_required";

    /// <summary>Home Assistant недоступен.</summary>
    public const string HaUnavailable = "ha_unavailable";
}
