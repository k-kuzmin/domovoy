using System.Diagnostics.CodeAnalysis;

namespace Domovoy.Core.Configuration;

/// <summary>
/// Распознавание незаполненных значений конфигурации.
///
/// Нужно потому, что валидация на старте проверяет форму, а не наличие
/// секретов: <c>docker compose up</c> на <c>.example</c>-конфигурации
/// обязан подниматься на чистой машине (ТЗ 5.1.3). Незаполненный секрет
/// даёт состояние «не сконфигурировано» в <c>/health</c>, а не падение
/// процесса.
/// </summary>
public static class PlaceholderValues
{
    private static readonly string[] Markers =
    [
        "example",
        "placeholder",
        "changeme",
        "change-me",
        "change_me",
        "replaceme",
        "your-",
        "your_",
        "dummy",
        "todo",
        "fillme",
        "notset",
        "not-set",
    ];

    /// <summary>
    /// Значение отсутствует или является плейсхолдером и потому не может
    /// использоваться как настоящий секрет или адрес.
    /// </summary>
    public static bool IsUnset([NotNullWhen(false)] string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        // Плейсхолдер вида <токен>, {{TOKEN}} или ${TOKEN}: подстановка
        // не выполнена.
        char first = value[0];
        if (first is '<' or '{' or '$')
        {
            return true;
        }

        string normalized = value.ToLowerInvariant();
        return Array.Exists(Markers, marker => normalized.Contains(marker, StringComparison.Ordinal));
    }
}
