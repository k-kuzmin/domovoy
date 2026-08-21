using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Allow-list сущностей (FR-HA-4, FR-HA-5).
///
/// Сущность, не попавшая в список, невидима для LLM и не может быть
/// изменена. Проверка выполняется в одном месте — на входе в слой
/// Home Assistant, а не в каждом инструменте: иначе достаточно одного
/// инструмента, где её забыли.
///
/// Результат вызова инструмента не может расширить этот список
/// (NFR-SEC-6).
/// </summary>
public interface IEntityAllowList
{
    /// <summary>Все разрешённые сущности.</summary>
    IReadOnlyList<HaEntityDescriptor> All { get; }

    /// <summary>Сущность разрешена и указанное действие для неё допустимо.</summary>
    bool IsActionAllowed(string entityId, string action);

    /// <summary>Описание сущности или <c>null</c>, если её нет в списке.</summary>
    HaEntityDescriptor? Find(string entityId);
}
