using System.Globalization;
using System.Text;
using Domovoy.Core.Models;

namespace Domovoy.Core.Prompts;

/// <summary>
/// Подстановка блоков в шаблон системного промпта.
///
/// Чистая функция без зависимостей — именно поэтому её можно проверить
/// тестом напрямую. Описания инструментов строятся из
/// <see cref="AgentToolDescriptor"/> зарегистрированных инструментов, а
/// не из отдельного списка: системный промпт и набор инструментов не
/// должны расходиться никогда.
/// </summary>
public static class SystemPromptComposer
{
    public static string Compose(
        IReadOnlyList<AgentToolDescriptor> tools,
        string homeProfile,
        string stateSlice,
        string memory)
    {
        ArgumentNullException.ThrowIfNull(tools);

        return SystemPromptTemplate.Text
            .Replace(SystemPromptTemplate.HomeProfilePlaceholder, Fallback(homeProfile, "профиль не задан"), StringComparison.Ordinal)
            .Replace(SystemPromptTemplate.StateSlicePlaceholder, Fallback(stateSlice, "состояний нет"), StringComparison.Ordinal)
            .Replace(SystemPromptTemplate.MemoryPlaceholder, Fallback(memory, "записей нет"), StringComparison.Ordinal)
            .Replace(SystemPromptTemplate.ToolsPlaceholder, DescribeTools(tools), StringComparison.Ordinal);
    }

    /// <summary>Описание набора инструментов для промпта.</summary>
    public static string DescribeTools(IReadOnlyList<AgentToolDescriptor> tools)
    {
        ArgumentNullException.ThrowIfNull(tools);

        if (tools.Count == 0)
        {
            return "инструментов нет";
        }

        var builder = new StringBuilder();

        foreach (AgentToolDescriptor tool in tools)
        {
            builder.Append(CultureInfo.InvariantCulture, $"- {tool.Name}: {tool.Description}");

            if (tool.Parameters.Count > 0)
            {
                string parameters = string.Join(
                    ", ",
                    tool.Parameters.Select(p => p.Required ? p.Name : p.Name + "?"));

                builder.Append(CultureInfo.InvariantCulture, $" Аргументы: {parameters}.");
            }

            if (tool.RequiresConfirmation)
            {
                builder.Append(" Требует подтверждения пользователем.");
            }

            builder.AppendLine();
        }

        return builder.ToString().TrimEnd();
    }

    private static string Fallback(string? value, string whenEmpty) =>
        string.IsNullOrWhiteSpace(value) ? whenEmpty : value;
}
