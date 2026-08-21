using System.Text.RegularExpressions;
using FluentAssertions;

namespace Domovoy.Tests;

/// <summary>
/// Раскладка мобильного клиента: логика в <c>Domovoy.Mobile.Core</c>,
/// MAUI — только в <c>Domovoy.Mobile.App</c>.
///
/// Мобильного клиента ещё нет, он появится на этапе 5 (issue #38).
/// Тест написан заранее и сейчас проходит вхолостую — это осознанно.
/// Правило дешёвое, пока переносить нечего, и дорогое потом: ViewModels,
/// сервисы и клиент API, написанные внутри MAUI-проекта, вынимаются
/// оттуда уже миграцией на десятки файлов.
///
/// Проверка работает с файлами, а не со сборками: ArchUnitNET загружает
/// сборки, а сборки <c>Domovoy.Mobile.Core</c> не существует — правило
/// на ней не выразить, пока проект не заведён. Когда он появится, к
/// этим тестам добавляется и правило ArchUnitNET в
/// <see cref="ArchitectureTests"/> — см. запись 0013.
///
/// Пустой список проектов не считается провалом: тест проверяет
/// отсутствие нарушений, а не наличие совпадений, — так же, как
/// <c>WithoutRequiringPositiveResults</c> в архитектурных правилах.
/// </summary>
public sealed class MobileLayeringTests
{
    private const string CoreProjectPattern = "Domovoy.Mobile.Core";

    /// <summary>
    /// Пакеты MAUI и всё, что тянет workload. Совпадение по началу
    /// имени: <c>Microsoft.Maui.Controls</c>, <c>Microsoft.Maui.Essentials</c>
    /// и прочие ловятся одним правилом.
    /// </summary>
    private static readonly string[] ForbiddenPackagePrefixes =
    [
        "Microsoft.Maui",
        "CommunityToolkit.Maui",
    ];

    private static readonly Regex PackageReference =
        new(@"<PackageReference\s+Include\s*=\s*""(?<name>[^""]+)""", RegexOptions.Compiled);

    private static readonly Regex TargetFramework =
        new(@"<TargetFrameworks?>(?<value>[^<]+)</TargetFrameworks?>", RegexOptions.Compiled);

    private static readonly Regex MauiUsing =
        new(@"^\s*(global\s+)?using\s+(static\s+)?(Microsoft|CommunityToolkit)\.Maui", RegexOptions.Compiled | RegexOptions.Multiline);

    [Fact(DisplayName = "Domovoy.Mobile.Core не ссылается на пакеты MAUI")]
    public void MobileCoreReferencesNoMauiPackages()
    {
        foreach (FileInfo project in RepositoryLayout.Projects(CoreProjectPattern))
        {
            string content = File.ReadAllText(project.FullName);

            List<string> forbidden = PackageReference.Matches(content)
                .Select(match => match.Groups["name"].Value)
                .Where(name => ForbiddenPackagePrefixes.Any(
                    prefix => name.StartsWith(prefix, StringComparison.Ordinal)))
                .ToList();

            forbidden.Should().BeEmpty(
                "{0} обязан собираться без MAUI-workload'ов: на нём держится быстрый цикл проверок",
                project.Name);

            content.Should().NotContain("<UseMaui>true</UseMaui>",
                "включённый UseMaui втягивает workload целиком");
        }
    }

    [Fact(DisplayName = "Domovoy.Mobile.Core собирается под платформо-независимый TFM")]
    public void MobileCoreTargetsPlatformNeutralFramework()
    {
        foreach (FileInfo project in RepositoryLayout.Projects(CoreProjectPattern))
        {
            string content = File.ReadAllText(project.FullName);

            List<string> platformSpecific = TargetFramework.Matches(content)
                .SelectMany(match => match.Groups["value"].Value.Split(';', StringSplitOptions.RemoveEmptyEntries))
                .Select(framework => framework.Trim())
                .Where(framework => framework.Contains('-', StringComparison.Ordinal))
                .ToList();

            platformSpecific.Should().BeEmpty(
                "{0} с платформенным TFM (net8.0-android и подобные) требует workload и перестаёт " +
                "собираться за секунды",
                project.Name);
        }
    }

    [Fact(DisplayName = "В коде Domovoy.Mobile.Core нет обращений к типам MAUI")]
    public void MobileCoreSourcesDoNotUseMauiTypes()
    {
        foreach (FileInfo project in RepositoryLayout.Projects(CoreProjectPattern))
        {
            IEnumerable<FileInfo> sources = project.Directory!
                .GetFiles("*.cs", SearchOption.AllDirectories)
                .Where(file => !IsBuildArtifact(file));

            List<string> offenders = sources
                .Where(file => MauiUsing.IsMatch(File.ReadAllText(file.FullName)))
                .Select(file => System.IO.Path.GetRelativePath(RepositoryLayout.Root.FullName, file.FullName))
                .ToList();

            offenders.Should().BeEmpty(
                "зависимость на MAUI выражается абстракцией в Core с реализацией в App — " +
                "навигация, диалоги, защищённое хранилище, состояние сети");
        }
    }

    private static bool IsBuildArtifact(FileInfo file) =>
        file.FullName.Contains($"{System.IO.Path.DirectorySeparatorChar}obj{System.IO.Path.DirectorySeparatorChar}", StringComparison.Ordinal)
        || file.FullName.Contains($"{System.IO.Path.DirectorySeparatorChar}bin{System.IO.Path.DirectorySeparatorChar}", StringComparison.Ordinal);
}
