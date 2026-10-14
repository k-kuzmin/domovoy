using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Клиент Home Assistant. Home Assistant наружу не выставлен, обращения
/// идут только из локальной сети (NFR-SEC-2).
/// </summary>
public interface IHaClient
{
    /// <summary>
    /// Состояния сущностей с фильтрацией по комнате и домену. Возвращает
    /// только то, что есть в allow-list.
    /// </summary>
    Task<IReadOnlyList<HaEntityState>> GetStatesAsync(
        string? area,
        string? domain,
        CancellationToken cancellationToken);

    /// <summary>
    /// Вызов действия над сущностью. Список доступных сервисов ограничен
    /// белым списком (раздел 4.3 ТЗ).
    /// </summary>
    /// <param name="domain">Домен сущности.</param>
    /// <param name="action">
    /// Имя действия из реестра сущности (allow-list), а не сервис HA;
    /// сервис и поле значения слой Ha выводит по своему каталогу доменов —
    /// это и есть белый список сервисов раздела 4.3 ТЗ.
    /// </param>
    /// <param name="entityId">Сущность из allow-list.</param>
    /// <param name="value">Значение действия или <c>null</c>, если действие его не принимает.</param>
    /// <param name="cancellationToken">Отмена вызова.</param>
    Task<ToolResult> CallServiceAsync(
        string domain,
        string action,
        string entityId,
        string? value,
        CancellationToken cancellationToken);

    /// <summary>История значений сущности за указанное число часов.</summary>
    Task<IReadOnlyList<HaEntityState>> GetHistoryAsync(
        string entityId,
        int hours,
        CancellationToken cancellationToken);

    /// <summary>Запуск сценария Home Assistant.</summary>
    Task<ToolResult> RunScriptAsync(string scriptId, CancellationToken cancellationToken);
}
