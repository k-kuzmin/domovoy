using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Шаблоны ответов (FR-CORE-7). Успешное изменяющее действие
/// формулируется шаблоном, повторный запрос к LLM не выполняется — это
/// убирает из цепочки самый дорогой участок.
///
/// Шаблоны хранятся в конфигурации рядом с реестром сущностей и
/// поддерживают склонение имени комнаты. Отсутствие шаблона — не
/// ошибка, а условие фолбэка на второй вызов LLM.
/// </summary>
public interface IResponseTemplates
{
    /// <summary>
    /// Текст ответа для пары «действие + сущность» или <c>null</c>,
    /// если шаблон не определён.
    /// </summary>
    string? TryRender(HaEntityDescriptor entity, string action);
}
