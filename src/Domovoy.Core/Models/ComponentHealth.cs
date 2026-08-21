namespace Domovoy.Core.Models;

/// <summary>
/// Состояние внешнего компонента.
///
/// <see cref="NotConfigured"/> существует отдельно от
/// <see cref="Unreachable"/> потому, что это разные ситуации с разными
/// действиями: в первом случае не заполнен секрет, во втором заполнен,
/// но связи нет. На <c>.example</c>-конфигурации все внешние компоненты
/// не сконфигурированы, и это не отказ — <c>docker compose up</c> на
/// чистой машине обязан подниматься (ТЗ 5.1.3).
/// </summary>
public enum ComponentState
{
    /// <summary>Компонент доступен и работает.</summary>
    Ok,

    /// <summary>Секрет или адрес не заполнены. Ожидаемое состояние на примерах.</summary>
    NotConfigured,

    /// <summary>Настроен, но недоступен по сети.</summary>
    Unreachable,

    /// <summary>
    /// Отказ по географии: провайдер ответил, но отклонил запрос из-за
    /// адреса источника. Отличать от сетевой ошибки требует AR-1.3.
    /// </summary>
    RejectedByGeography,

    /// <summary>Прочая ошибка.</summary>
    Error,
}

/// <summary>Результат проверки компонента для <c>/health</c> (NFR-OBS-3).</summary>
public sealed record ComponentHealth
{
    public required ComponentState State { get; init; }

    /// <summary>
    /// Описание для человека. Не содержит секретов, адресов и имён
    /// хостов: подробный статус доступен под токеном, но и там
    /// приватным данным места нет.
    /// </summary>
    public required string Description { get; init; }

    public static ComponentHealth Ok(string description) =>
        new() { State = ComponentState.Ok, Description = description };

    public static ComponentHealth NotConfigured(string description) =>
        new() { State = ComponentState.NotConfigured, Description = description };

    public static ComponentHealth Unreachable(string description) =>
        new() { State = ComponentState.Unreachable, Description = description };

    public static ComponentHealth Error(string description) =>
        new() { State = ComponentState.Error, Description = description };
}
