using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Domovoy.Voice;

/// <summary>Регистрация слоя голоса.</summary>
public static class VoiceServiceCollectionExtensions
{
    public const string SpeechToTextClientName = "stt";
    public const string TextToSpeechClientName = "tts";

    public static IServiceCollection AddVoice(this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddHttpClient<ISpeechToText, WhisperSpeechToText>(
            SpeechToTextClientName,
            (serviceProvider, client) =>
            {
                VoiceOptions options = serviceProvider.GetRequiredService<IOptions<VoiceOptions>>().Value;
                client.BaseAddress = new Uri(options.SpeechToTextUrl.TrimEnd('/') + '/');
                client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
            });

        services.AddHttpClient<ITextToSpeech, PiperTextToSpeech>(
            TextToSpeechClientName,
            (serviceProvider, client) =>
            {
                VoiceOptions options = serviceProvider.GetRequiredService<IOptions<VoiceOptions>>().Value;

                // Озвучка опциональна: без адреса сервиса клиент
                // остаётся без базового адреса, а вызов инструмента
                // отклоняется на уровне эндпоинта.
                if (!PlaceholderValues.IsUnset(options.TextToSpeechUrl))
                {
                    client.BaseAddress = new Uri(options.TextToSpeechUrl.TrimEnd('/') + '/');
                }

                client.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
            });

        return services;
    }
}
