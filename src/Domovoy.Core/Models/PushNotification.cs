namespace Domovoy.Core.Models;

/// <summary>
/// Приоритет уведомления. Маппится на приоритеты ntfy (FR-PUSH-2):
/// <see cref="Urgent"/> обходит режим «не беспокоить».
/// </summary>
public enum NotificationPriority
{
    Low,
    Default,
    High,
    Urgent,
}

/// <summary>Уведомление для отправки на устройство пользователя.</summary>
public sealed record PushNotification
{
    public required string Title { get; init; }

    public required string Body { get; init; }

    public required NotificationPriority Priority { get; init; }

    /// <summary>
    /// Deep link, открывающий соответствующий экран приложения
    /// (FR-PUSH-4).
    /// </summary>
    public string? DeepLink { get; init; }
}
