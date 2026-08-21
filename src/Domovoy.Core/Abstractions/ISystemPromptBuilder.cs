using Domovoy.Core.Models;

namespace Domovoy.Core.Abstractions;

/// <summary>
/// Сборка системного промпта: профиль дома, отфильтрованный срез
/// состояний, релевантные факты памяти, описания инструментов.
///
/// Описания инструментов берутся из <see cref="IAgentTool.Descriptor"/>
/// зарегистрированных инструментов, а не из отдельного списка: промпт и
/// набор инструментов не должны расходиться никогда. Это проверяется
/// обязательным тестом.
/// </summary>
public interface ISystemPromptBuilder
{
    Task<string> BuildAsync(
        AgentRequest request,
        IReadOnlyList<HaEntityState> stateSlice,
        CancellationToken cancellationToken);
}
