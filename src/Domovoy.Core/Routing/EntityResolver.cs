using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing;

/// <summary>
/// Разрешение «устройство + комната» из фразы в сущность allow-list.
///
/// Комната узнаётся по падежам реестра: предложному с предлогом («на
/// кухне») или родительному («кухни»). Устройство — слова, оставшиеся после
/// комнаты; каждое должно совпасть по основе со словом имени сущности, из
/// которого убрана её собственная комната («Свет на кухне» → «свет»).
///
/// Совпадение — только единственный кандидат. Неоднозначность, две
/// комнаты во фразе или ни одного кандидата — нет совпадения, и фраза
/// уходит на путь через LLM. Это разрешение имени, а не проверка
/// безопасности: allow-list проверяет слой Home Assistant.
/// </summary>
internal static class EntityResolver
{
    private const int MinStemPrefixLength = 4;

    private static readonly HashSet<string> Fillers = new(StringComparer.Ordinal) { "пожалуйста" };

    private static readonly char[] Endings = ['а', 'е', 'и', 'о', 'у', 'ы', 'э', 'ю', 'я', 'ь', 'й'];

    /// <summary>Слова нормализованной фразы без вежливых вставок.</summary>
    public static List<string> Tokenize(string normalizedText) =>
        normalizedText
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(token => !Fillers.Contains(token))
            .ToList();

    /// <summary>
    /// Единственная сущность, подходящая под слова фразы и фильтр, или
    /// <c>null</c>.
    /// </summary>
    /// <param name="tokens">Слова устройства и комнаты, без глагола и значения.</param>
    /// <param name="allowList">Реестр сущностей и комнат.</param>
    /// <param name="isCandidate">Фильтр шаблона: домен, действие.</param>
    /// <param name="deviceRequired">
    /// Фраза обязана назвать устройство. Без этого кандидатом считается
    /// любая сущность комнаты, прошедшая фильтр.
    /// </param>
    public static HaEntityDescriptor? Resolve(
        IReadOnlyList<string> tokens,
        IEntityAllowList allowList,
        Func<HaEntityDescriptor, bool> isCandidate,
        bool deviceRequired)
    {
        var rest = tokens.Where(token => !Fillers.Contains(token)).ToList();

        HaAreaDescriptor? area = null;
        foreach (HaAreaDescriptor candidateArea in allowList.Areas)
        {
            if (!RemoveArea(rest, candidateArea))
            {
                continue;
            }

            if (area is not null)
            {
                return null;
            }

            area = candidateArea;
        }

        if (deviceRequired && rest.Count == 0)
        {
            return null;
        }

        HaEntityDescriptor? found = null;
        foreach (HaEntityDescriptor entity in allowList.All)
        {
            if (area is not null && !string.Equals(entity.Area, area.Id, StringComparison.Ordinal))
            {
                continue;
            }

            if (!isCandidate(entity) || !DeviceMatches(rest, DeviceWords(entity, allowList)))
            {
                continue;
            }

            if (found is not null)
            {
                return null;
            }

            found = entity;
        }

        return found;
    }

    /// <summary>Действие есть в реестре сущности.</summary>
    public static bool Allows(HaEntityDescriptor entity, string action) =>
        entity.AllowedActions.Contains(action, StringComparer.Ordinal);

    /// <summary>Слова совпадают по основе: «протечка» и «протечки», «кондиционер» и «кондиционером».</summary>
    public static bool SameStem(string left, string right)
    {
        string a = Stem(left);
        string b = Stem(right);
        if (string.Equals(a, b, StringComparison.Ordinal))
        {
            return true;
        }

        (string shorter, string longer) = a.Length <= b.Length ? (a, b) : (b, a);
        return shorter.Length >= MinStemPrefixLength && longer.StartsWith(shorter, StringComparison.Ordinal);
    }

    private static string Stem(string word)
    {
        int length = word.Length;
        while (length > 3 && Array.IndexOf(Endings, word[length - 1]) >= 0)
        {
            length--;
        }

        return word[..length];
    }

    private static bool DeviceMatches(List<string> phraseWords, List<string> deviceWords) =>
        phraseWords.All(word => deviceWords.Exists(deviceWord => SameStem(word, deviceWord)));

    /// <summary>Слова имени сущности без её собственной комнаты: «Свет на кухне» → «свет».</summary>
    private static List<string> DeviceWords(HaEntityDescriptor entity, IEntityAllowList allowList)
    {
        List<string> words = Tokenize(PhraseNormalizer.Normalize(entity.FriendlyName));
        HaAreaDescriptor? own = allowList.FindArea(entity.Area);
        if (own is not null)
        {
            RemoveArea(words, own);
        }

        return words;
    }

    /// <summary>Убрать из слов упоминание комнаты: сначала предложный падеж, затем родительный.</summary>
    private static bool RemoveArea(List<string> words, HaAreaDescriptor area) =>
        RemoveSequence(words, area.Prepositional)
        || (area.Genitive is not null && RemoveSequence(words, area.Genitive));

    private static bool RemoveSequence(List<string> words, string phrase)
    {
        List<string> sequence = Tokenize(PhraseNormalizer.Normalize(phrase));
        if (sequence.Count == 0)
        {
            return false;
        }

        for (int start = 0; start + sequence.Count <= words.Count; start++)
        {
            bool equal = true;
            for (int offset = 0; offset < sequence.Count && equal; offset++)
            {
                equal = string.Equals(words[start + offset], sequence[offset], StringComparison.Ordinal);
            }

            if (equal)
            {
                words.RemoveRange(start, sequence.Count);
                return true;
            }
        }

        return false;
    }
}
