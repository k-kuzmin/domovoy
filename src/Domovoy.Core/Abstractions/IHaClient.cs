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
    /// Вызов сервиса Home Assistant. Список доступных сервисов ограничен
    /// белым списком (раздел 4.3 ТЗ).
    /// </summary>
    Task<ToolResult> CallServiceAsync(
        string domain,
        string service,
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
