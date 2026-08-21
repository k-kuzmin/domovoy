using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Проверка доступности внешнего компонента для <c>/health</c>
/// (NFR-OBS-3).
///
/// Каждый периферийный слой предоставляет свою реализацию: слой Api не
/// должен знать, как проверяется Home Assistant или конкретный
/// провайдер LLM.
/// </summary>
public interface IComponentProbe
{
    /// <summary>Имя компонента в ответе <c>/health</c>: <c>db</c>, <c>ha</c>, <c>llm</c>.</summary>
    string ComponentName { get; }

    /// <summary>
    /// Проверить компонент. Реализация не бросает исключений: отказ
    /// диагностики не имеет права уронить <c>/health</c>.
    /// </summary>
    Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken);
}
