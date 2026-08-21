using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Правила проактивности (FR-PRO-2). Решение об отправке —
/// детерминированное правило, LLM привлекается только для формулировки
/// текста (FR-PRO-4): это защищает от ложных срабатываний и лишних
/// токенов.
///
/// Критичные для безопасности автоматизации (протечка перекрывает воду,
/// задымление включает сирену) реализуются на стороне Home Assistant, а
/// не здесь: они обязаны срабатывать при остановленном Backend и без
/// интернета (AR-6).
/// </summary>
public interface IProactiveRuleEngine
{
    /// <summary>
    /// Уведомление, которое следует отправить по событию, или
    /// <c>null</c>. Учитывает антиспам-окно: одно правило не срабатывает
    /// повторно в течение заданного интервала (FR-PRO-5).
    /// </summary>
    Task<PushNotification?> EvaluateAsync(HaStateChange change, CancellationToken cancellationToken);
}
