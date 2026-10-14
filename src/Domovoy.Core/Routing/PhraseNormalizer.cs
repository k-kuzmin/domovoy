using System.Text;

namespace Domovoy.Core.Routing;

/// <summary>
/// Нормализация фразы для шаблонов быстрого пути: нижний регистр, «ё»
/// заменена на «е», без знаков препинания, одиночные пробелы.
///
/// Точка и запятая между двумя цифрами — часть числа, а не знак
/// препинания: «23,5 градуса» остаётся «23,5». Значение уходит в слой
/// Home Assistant как есть, запятую разбирает он.
/// </summary>
internal static class PhraseNormalizer
{
    public static string Normalize(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var builder = new StringBuilder(text.Length);
        bool pendingSpace = false;

        for (int i = 0; i < text.Length; i++)
        {
            char current = char.ToLowerInvariant(text[i]);
            if (current == 'ё')
            {
                current = 'е';
            }

            bool keep = char.IsLetterOrDigit(current) || IsDecimalSeparator(text, i);
            if (!keep)
            {
                pendingSpace = builder.Length > 0;
                continue;
            }

            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }

            builder.Append(current);
        }

        return builder.ToString();
    }

    private static bool IsDecimalSeparator(string text, int index) =>
        text[index] is '.' or ','
        && index > 0
        && index < text.Length - 1
        && char.IsDigit(text[index - 1])
        && char.IsDigit(text[index + 1]);
}
