using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Отправка push-уведомлений. Топик на пользователя, имя топика —
/// случайная строка достаточной энтропии (FR-PUSH-1).
///
/// Имя топика функционально является паролем: знающий его читает
/// уведомления и отправляет свои. Оно приходит из конфигурации и не
/// логируется никогда.
/// </summary>
public interface IPushSender
{
    Task SendAsync(PushNotification notification, CancellationToken cancellationToken);
}
