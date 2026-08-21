using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Инструмент агента.
///
/// Новый инструмент добавляется одним классом: реализовать интерфейс,
/// зарегистрировать в DI. Оркестратор обнаруживает инструменты через
/// <c>IEnumerable&lt;IAgentTool&gt;</c> и не содержит ветвлений по их
/// именам. Если новый инструмент требует правки оркестратора — это
/// признак неполной абстракции, расширять надо интерфейс.
/// </summary>
public interface IAgentTool
{
    /// <summary>
    /// Описание инструмента. Единственный источник истины: и схема для
    /// модели, и запись в системном промпте строятся отсюда.
    /// </summary>
    AgentToolDescriptor Descriptor { get; }

    /// <summary>
    /// Выполнить вызов. Реализация обязана валидировать аргументы:
    /// любой <c>entity_id</c> проверяется по allow-list до обращения к
    /// Home Assistant (FR-HA-4).
    /// </summary>
    Task<ToolResult> ExecuteAsync(ToolCall toolCall, CancellationToken cancellationToken);
}
