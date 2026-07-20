sealed class TranslateException implements Exception {
  String get message;
}

class InvalidApiKeyException implements TranslateException {
  @override
  String get message => 'Provided API key is not valid';
}

class UnsupportedUserLocationException implements TranslateException {
  @override
  String get message =>
      'Gemini API is not available in your location. Use '
      'Vertex AI model provider. See the documentation for more information';
}

class SafetyException implements TranslateException {
  @override
  String get message =>
      'Translation failed due to safety settings. You can disable safety '
      'settings using --disable-safety flag or with '
      'arb-translate-disable-safety: true in l10n.yaml';
}

class QuotaExceededException implements TranslateException {
  @override
  String get message => 'Quota exceeded';
}

class NoResponseException implements TranslateException {
  @override
  String get message => 'Failed to get a response from the model';
}

class ResponseParsingException implements TranslateException {
  @override
  String get message => 'Failed to parse API response';
}

class PlaceholderValidationException implements TranslateException {
  const PlaceholderValidationException({
    this.locale,
    this.messageKey,
    this.details,
  });

  final String? locale;
  final String? messageKey;
  final String? details;

  @override
  String get message {
    if (locale == null || messageKey == null) {
      return 'Placeholder validation failed';
    }

    return 'Placeholder validation failed for locale "$locale", message '
        '"$messageKey"${details == null ? '' : ': $details'}';
  }
}
