namespace Domovoy.Core.Models;

/// <summary>
/// Описание инструмента: то, что попадает в схему для LLM и в системный
/// промпт. Источник истины один — сам инструмент; тест проверяет, что
/// каждый зарегистрированный инструмент присутствует в промпте.
/// </summary>
public sealed record AgentToolDescriptor
{
    /// <summary>Имя, которым модель вызывает инструмент.</summary>
    public required string Name { get; init; }

    /// <summary>Описание для модели.</summary>
    public required string Description { get; init; }

    public required IReadOnlyList<ToolParameter> Parameters { get; init; }

    /// <summary>
    /// Инструмент меняет состояние дома. Такие вызовы пишутся в
    /// аудит-лог (FR-CORE-6) и могут закрываться шаблонным ответом без
    /// второго обращения к LLM (FR-CORE-7).
    /// </summary>
    public bool IsMutating { get; init; }

    /// <summary>Требует подтверждения вторым сообщением.</summary>
    public bool RequiresConfirmation { get; init; }
}
