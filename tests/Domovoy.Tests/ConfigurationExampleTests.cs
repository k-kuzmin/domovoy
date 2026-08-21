using System.Text.Json;
using System.Text.RegularExpressions;
using Domovoy.Core.Configuration;
using FluentAssertions;

namespace Domovoy.Tests;

/// <summary>
/// Синхронность конфигурации и её примеров.
///
/// Это то, что разъезжается чаще всего: параметр добавили в
/// docker-compose, а в <c>.env.example</c> забыли — и
/// <c>docker compose up</c> на чистой машине падает у следующего
/// человека, а не у автора правки. Проверка механическая, потому что
/// вниманием эта задача не решается.
/// </summary>
public sealed class ConfigurationExampleTests
{
    private static readonly Regex VariableReference =
        new(@"\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*)(?::?-[^}]*)?\}", RegexOptions.Compiled);

    private static readonly string[] SecretSettingPaths =
    [
        "Ha:Token",
        "Llm:ApiKey",
        "Ntfy:Topic",
    ];

    [Fact(DisplayName = "Каждая переменная из docker-compose.yml описана в .env.example")]
    public void ComposeVariablesAreDocumentedInEnvExample()
    {
        string compose = File.ReadAllText(RepositoryLayout.Path("docker-compose.yml"));
        string envExample = File.ReadAllText(RepositoryLayout.Path(".env.example"));

        HashSet<string> declared = ParseEnvKeys(envExample);

        List<string> referenced = VariableReference.Matches(compose)
            .Select(match => match.Groups["name"].Value)
            .Distinct(StringComparer.Ordinal)
            .ToList();

        referenced.Should().NotBeEmpty("compose параметризован переменными окружения");

        List<string> missing = referenced
            .Where(name => !declared.Contains(name))
            .ToList();

        missing.Should().BeEmpty(
            "переменная, которой нет в .env.example, ломает запуск на чистой машине");
    }

    [Fact(DisplayName = "Пример переопределений ссылается только на описанные переменные")]
    public void OverrideExampleUsesDocumentedVariables()
    {
        string over = File.ReadAllText(RepositoryLayout.Path("docker-compose.override.example.yml"));
        HashSet<string> declared = ParseEnvKeys(File.ReadAllText(RepositoryLayout.Path(".env.example")));

        List<string> missing = VariableReference.Matches(over)
            .Select(match => match.Groups["name"].Value)
            .Distinct(StringComparer.Ordinal)
            .Where(name => !declared.Contains(name))
            .ToList();

        missing.Should().BeEmpty();
    }

    [Fact(DisplayName = "В appsettings.json нет заполненных секретов")]
    public void AppSettingsCarryNoSecrets()
    {
        using FileStream stream = File.OpenRead(
            RepositoryLayout.Path("src", "Domovoy.Api", "appsettings.json"));
        using JsonDocument document = JsonDocument.Parse(stream);

        foreach (string path in SecretSettingPaths)
        {
            string? value = ReadPath(document.RootElement, path);

            PlaceholderValues.IsUnset(value).Should().BeTrue(
                $"значение {path} лежит в файле проекта — там может быть только плейсхолдер");
        }
    }

    [Fact(DisplayName = "У каждого примера конфигурации есть закрытый .gitignore двойник")]
    public void EveryExampleHasIgnoredCounterpart()
    {
        string gitignore = File.ReadAllText(RepositoryLayout.Path(".gitignore"));
        string configDirectory = RepositoryLayout.Path("config");

        List<string> examples = Directory
            .EnumerateFiles(configDirectory, "*.example.*", SearchOption.TopDirectoryOnly)
            .Select(Path.GetFileName)
            .Where(name => name is not null)
            .Select(name => name!)
            .ToList();

        examples.Should().NotBeEmpty(".example-файлы обязаны быть в репозитории");

        // Реальный файл получается отбрасыванием «.example» из имени.
        // Его расширение должно быть закрыто правилом в .gitignore,
        // иначе реестр сущностей однажды уедет в публичную историю.
        foreach (string example in examples)
        {
            string extension = Path.GetExtension(example);

            gitignore.Should().Contain($"config/*{extension}",
                $"расширение {extension} используется примером {example}, значит реальный файл должен быть закрыт");
        }

        gitignore.Should().Contain("!config/*.example.*",
            "без исключения примеры выпадут из репозитория вместе с реальными файлами");
    }

    private static HashSet<string> ParseEnvKeys(string content)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal);

        foreach (string line in content.Split('\n'))
        {
            string trimmed = line.Trim();

            if (trimmed.Length == 0 || trimmed.StartsWith('#'))
            {
                continue;
            }

            int separator = trimmed.IndexOf('=', StringComparison.Ordinal);

            if (separator > 0)
            {
                keys.Add(trimmed[..separator].Trim());
            }
        }

        return keys;
    }

    private static string? ReadPath(JsonElement root, string path)
    {
        JsonElement current = root;

        foreach (string segment in path.Split(':'))
        {
            if (!current.TryGetProperty(segment, out current))
            {
                return null;
            }
        }

        return current.ValueKind == JsonValueKind.String ? current.GetString() : null;
    }
}
