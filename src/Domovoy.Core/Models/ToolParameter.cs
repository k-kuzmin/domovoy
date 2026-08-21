using System.Diagnostics.CodeAnalysis;

namespace Domovoy.Core.Models;

/// <summary>
/// Тип аргумента инструмента. Набор намеренно узкий: схемы держим
/// плоскими, максимум 2 уровня — GigaChat хуже работает с вложенными
/// JSON-схемами (раздел 3 ТЗ).
/// </summary>
[SuppressMessage(
    "Naming",
    "CA1720:Identifier contains type name",
    Justification = "Имена элементов повторяют типы JSON Schema — это формат обмена с провайдером LLM, а не типы C#. Переименование рассинхронизировало бы схему инструмента и её сериализацию.")]
public enum ToolParameterType
{
    String,
    Integer,
    Number,
    Boolean,
}

/// <summary>Аргумент инструмента.</summary>
public sealed record ToolParameter
{
    public required string Name { get; init; }

    public required ToolParameterType Type { get; init; }

    /// <summary>Описание для модели. Попадает в схему инструмента.</summary>
    public required string Description { get; init; }

    public bool Required { get; init; }

    /// <summary>Допустимые значения, если их набор закрыт.</summary>
    public IReadOnlyList<string>? AllowedValues { get; init; }
}
