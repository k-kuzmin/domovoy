namespace Domovoy.Tests;

/// <summary>
/// Доступ к файлам репозитория из тестов.
///
/// Тест, который проверяет раскладку проектов или синхронность
/// примеров конфигурации, работает не со сборками, а с файлами. Путь к
/// ним считается от корня репозитория, а не от каталога сборки: он
/// разный у <c>dotnet test</c>, у IDE и у CI.
/// </summary>
internal static class RepositoryLayout
{
    /// <summary>
    /// Корень репозитория. Определяется по <c>Domovoy.sln</c>: файл
    /// лежит ровно в одном месте, а подниматься по каталогам от сборки
    /// надёжнее, чем считать количество <c>..</c> — оно меняется от
    /// конфигурации и TFM.
    /// </summary>
    public static DirectoryInfo Root { get; } = FindRoot();

    /// <summary>Абсолютный путь к файлу или каталогу репозитория.</summary>
    public static string Path(params string[] relativeSegments) =>
        System.IO.Path.Combine([Root.FullName, .. relativeSegments]);

    /// <summary>
    /// Каталоги проектов, имя которых совпадает с образцом
    /// (например <c>Domovoy.Mobile.*</c>). Пустой результат — не ошибка:
    /// проект может быть ещё не заведён.
    /// </summary>
    public static IReadOnlyList<FileInfo> Projects(string searchPattern) =>
        Root.GetDirectories("src", SearchOption.TopDirectoryOnly)
            .SelectMany(source => source.GetFiles($"{searchPattern}.csproj", SearchOption.AllDirectories))
            .OrderBy(file => file.FullName, StringComparer.Ordinal)
            .ToList();

    private static DirectoryInfo FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null && !File.Exists(System.IO.Path.Combine(directory.FullName, "Domovoy.sln")))
        {
            directory = directory.Parent;
        }

        return directory
            ?? throw new InvalidOperationException(
                "Корень репозитория не найден: от каталога сборки вверх нет Domovoy.sln.");
    }
}
