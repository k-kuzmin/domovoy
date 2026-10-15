namespace Domovoy.Api.Security;

/// <summary>Имена схем, политик авторизации и политики лимитера.</summary>
public static class DeviceTokenDefaults
{
    /// <summary>Схема аутентификации устройства по токену.</summary>
    public const string SchemeName = "DeviceToken";

    /// <summary>Схема аутентификации администратора по общему секрету.</summary>
    public const string AdminSchemeName = "AdminToken";

    /// <summary>Политика авторизации админ-эндпоинтов.</summary>
    public const string AdminPolicyName = "admin";

    /// <summary>Политика ограничения частоты обмена кода привязки.</summary>
    public const string PairingRateLimitPolicy = "pairing";
}
