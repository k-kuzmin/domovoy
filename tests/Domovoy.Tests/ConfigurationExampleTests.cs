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

    private static readonly Regex HaProfile =
        new(@"^profiles:\s*\[\s*['""]?ha['""]?\s*\]$", RegexOptions.Compiled);

    private static readonly Regex DbOnlyNetwork =
        new(@"^networks:\s*\[\s*['""]?db['""]?\s*\]$", RegexOptions.Compiled);

    private static readonly Regex DefaultOnlyNetwork =
        new(@"^networks:\s*\[\s*['""]?default['""]?\s*\]$", RegexOptions.Compiled);

    private static readonly string[] SecretSettingPaths =
    [
        "Auth:AdminToken",
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

    [Fact(DisplayName = "HA_TOKEN в .env.example — фиктивное значение, а не пустое и не настоящее")]
    public void HaTokenExampleIsFictitiousPlaceholder()
    {
        Dictionary<string, string> values = ParseEnvValues(
            File.ReadAllText(RepositoryLayout.Path(".env.example")));

        values.Should().ContainKey("HA_TOKEN", "ключ перечислен в примере (ТЗ 5.1.2)");

        string value = values["HA_TOKEN"];

        value.Should().NotBeNullOrWhiteSpace("ключ перечислен с фиктивным значением, а не пустым");
        PlaceholderValues.IsUnset(value).Should().BeTrue(
            "фиктивное значение обязано распознаваться как плейсхолдер — иначе на чистой машине проба HA пойдёт с мусорным токеном");
    }

    [Fact(DisplayName = "Сценарий «утерян телефон» в README — одна строка curl с плейсхолдерами")]
    public void ReadmeLostPhoneScenarioIsOneCurlLine()
    {
        // Строковая проверка без сборки приложения: сверка пути с маршрутом
        // админ-эндпоинта — работа ревью диффа (#13, A13-readme).
        List<string> lines = File.ReadAllLines(RepositoryLayout.Path("README.md"))
            .Where(line => line.Contains("curl -X DELETE", StringComparison.Ordinal))
            .ToList();

        lines.Should().ContainSingle(
            "отзыв утерянного устройства описан одной командой — вторая копия разъедется с первой");

        string command = lines[0];

        command.Should().Contain("https://api.example.com/", "в README только плейсхолдер хоста (запись 0001)");
        command.Should().Contain("<admin-token>", "секрет в README — только плейсхолдером");
        command.Should().Contain("/api/v1/admin/devices/<device-id>", "команда отзывает одно устройство по его id");
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

    [Fact(DisplayName = "Home Assistant в compose — только под профилем ha и с автозапуском")]
    public void HomeAssistantServiceIsOptInAndRestartsAutomatically()
    {
        Dictionary<string, List<string>> services = ParseComposeServices(
            File.ReadAllText(RepositoryLayout.Path("docker-compose.yml")));

        services.Should().ContainKey("homeassistant", "Home Assistant поднимается в общем стеке");

        List<string> homeAssistant = services["homeassistant"];

        homeAssistant.Should().Contain(
            line => HaProfile.IsMatch(line),
            "без профиля docker compose up на чистой машине и в CI тянет образ Home Assistant");
        homeAssistant.Should().Contain(
            "restart: unless-stopped",
            "Home Assistant поднимается сам после перезагрузки машины (AR-5)");

        foreach (string name in new[] { "postgres", "api" })
        {
            services.Should().ContainKey(name);
            services[name].Should().NotContain(
                line => line.StartsWith("profiles:", StringComparison.Ordinal),
                $"сервис {name} входит в стек по умолчанию — профиль выключил бы его из docker compose up");
        }
    }

    [Fact(DisplayName = "Каждый сервис compose поднимается сам после перезагрузки хоста")]
    public void EveryComposeServiceRestartsAutomatically()
    {
        Dictionary<string, List<string>> services = ParseComposeServices(
            File.ReadAllText(RepositoryLayout.Path("docker-compose.yml")));

        services.Should().ContainKeys(["postgres", "api", "homeassistant"],
            "разбор compose обязан видеть сервисы стека, иначе проверять нечего");

        // После перезагрузки контейнеры поднимает демон по политике restart,
        // а не docker compose up (AR-5, #6). Сервис без политики остаётся
        // лежать до ручного запуска — в том числе под профилем.
        foreach ((string name, List<string> keys) in services)
        {
            keys.Should().Contain(
                "restart: unless-stopped",
                $"сервис {name} должен подниматься демоном после перезагрузки хоста без ручных действий");
        }
    }

    [Fact(DisplayName = "База в compose — в своей сети, Home Assistant до неё не достаёт")]
    public void PostgresIsIsolatedFromHomeAssistant()
    {
        Dictionary<string, List<string>> services = ParseComposeServices(
            File.ReadAllText(RepositoryLayout.Path("docker-compose.yml")));

        services["postgres"].Should().Contain(
            line => DbOnlyNetwork.IsMatch(line),
            "без своей сети база в default — там же, где Home Assistant");
        services["api"].Should().Contain(
            line => line.StartsWith("networks:", StringComparison.Ordinal)
                && line.Contains("default", StringComparison.Ordinal)
                && line.Contains("db", StringComparison.Ordinal),
            "Backend ходит и в базу, и к Home Assistant по имени сервиса");
        // Блочную форму списка разбор не видит (берёт только ключи), поэтому
        // у Home Assistant допустимы лишь отсутствие сетей или ровно default.
        services["homeassistant"].Should().NotContain(
            line => line.StartsWith("networks:", StringComparison.Ordinal)
                && !DefaultOnlyNetwork.IsMatch(line),
                "Home Assistant с внешними интеграциями не должен видеть базу");
    }

    /// <summary>
    /// Ключи первого уровня каждого сервиса из секции <c>services:</c>.
    /// Сервис — строка на отступе 2, его блок — до следующей значимой
    /// строки с отступом не больше 2. Пустые строки и комментарии не
    /// значимы: закомментированный ключ не действует и не должен засчитываться.
    /// </summary>
    private static Dictionary<string, List<string>> ParseComposeServices(string compose)
    {
        var services = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        bool inServices = false;
        List<string>? current = null;

        foreach (string raw in compose.Split('\n'))
        {
            string line = raw.TrimEnd('\r', ' ', '\t');
            string trimmed = line.TrimStart(' ');

            if (trimmed.Length == 0 || trimmed.StartsWith('#'))
            {
                continue;
            }

            int indent = line.Length - trimmed.Length;

            if (indent == 0)
            {
                inServices = trimmed == "services:";
                current = null;
                continue;
            }

            if (!inServices)
            {
                continue;
            }

            if (indent <= 2)
            {
                string name = trimmed.TrimEnd(':');
                current = [];
                services[name] = current;
                continue;
            }

            if (indent == 4)
            {
                current?.Add(trimmed);
            }
        }

        return services;
    }

    private static HashSet<string> ParseEnvKeys(string content) =>
        ParseEnvValues(content).Keys.ToHashSet(StringComparer.Ordinal);

    private static Dictionary<string, string> ParseEnvValues(string content)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);

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
                values[trimmed[..separator].Trim()] = trimmed[(separator + 1)..].Trim();
            }
        }

        return values;
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
