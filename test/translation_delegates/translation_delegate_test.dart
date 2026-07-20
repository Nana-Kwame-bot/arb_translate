import 'dart:convert';

import 'package:arb_translate/src/flutter_tools/gen_l10n_types.dart';
import 'package:arb_translate/src/flutter_tools/localizations_utils.dart';
import 'package:arb_translate/src/translation_delegates/translate_exception.dart';
import 'package:arb_translate/src/translation_delegates/translation_delegate.dart';
import 'package:arb_translate/src/write_updated_bundle.dart';
import 'package:file/local.dart';
import 'package:test/test.dart';

class NoOpTranslationDelegate extends TranslationDelegate {
  const NoOpTranslationDelegate({
    super.relaxSyntax = false,
    super.useEscaping = false,
  })
      : super(
          batchSize: 4096,
          context: null,
        );

  @override
  int get batchSize => throw UnimplementedError();

  @override
  int get maxParallelQueries => throw UnimplementedError();

  @override
  int get maxRetryCount => throw UnimplementedError();

  @override
  Duration get queryBackoff => throw UnimplementedError();

  @override
  Future<String> getModelResponse(
      Map<String, Object?> resources, LocaleInfo locale) {
    throw UnimplementedError();
  }
}

class StubTranslationDelegate extends TranslationDelegate {
  StubTranslationDelegate(this.response)
      : super(
          batchSize: 4096,
          context: null,
          useEscaping: false,
          relaxSyntax: false,
        );

  final String response;
  var requestCount = 0;

  @override
  int get maxParallelQueries => 1;

  @override
  int get maxRetryCount => 1;

  @override
  Duration get queryBackoff => Duration.zero;

  @override
  Future<String> getModelResponse(
    Map<String, Object?> resources,
    LocaleInfo locale,
  ) async {
    requestCount++;

    return response;
  }
}

const messageKey = 'deleteAccountSubscriptionNotice';
const templateMessage =
    'Deleting your account does not cancel your subscription. '
    "If it's still active, cancel it separately to stop future billing.";
const inventedPluralMessage =
    '{count, plural, one{Deleting your account does not cancel your '
    "subscription. If it's still active, cancel it separately to stop future "
    'billing.} other{Deleting your account does not cancel your subscriptions. '
    "If they're still active, cancel them separately to stop future billing.}}";

void main() {
  group(
    'TranslationDelegate',
    () {
      final delegate = NoOpTranslationDelegate();

      test(
        'validateResults returns true for resources without placeholders',
        () {
          final resources = {'key': 'value'};
          final results = {'key': 'translateValue'};

          expect(delegate.validateResults(resources, results), isTrue);
        },
      );

      test(
        'validateResults preserves literal braces with relaxed syntax',
        () {
          final delegate = NoOpTranslationDelegate(relaxSyntax: true);
          final resources = {'key': 'Use {braces} literally'};
          final results = {'key': 'Verwende {Klammern} wörtlich'};

          expect(delegate.validateResults(resources, results), isTrue);
        },
      );

      test(
        'validateResults preserves quoted ICU text with relaxed syntax',
        () {
          final delegate = NoOpTranslationDelegate(
            relaxSyntax: true,
            useEscaping: true,
          );
          final resources = {
            'key': "Show '{count, plural, one{one} other{many}}' literally",
          };
          final results = {
            'key': "Zeige '{count, plural, one{eins} other{viele}}' wörtlich",
          };

          expect(delegate.validateResults(resources, results), isTrue);
        },
      );

      test(
        'validateResults returns false for an invented plural placeholder',
        () {
          final resources = {messageKey: templateMessage};
          final results = {messageKey: inventedPluralMessage};

          expect(delegate.validateResults(resources, results), isFalse);
        },
      );

      test(
        'validateResults rejects an invented plural with relaxed syntax',
        () {
          final delegate = NoOpTranslationDelegate(relaxSyntax: true);
          final resources = {messageKey: templateMessage};
          final results = {messageKey: inventedPluralMessage};

          expect(delegate.validateResults(resources, results), isFalse);
        },
      );

      test(
        'relaxed syntax cannot hide an invented plural after literal braces',
        () {
          final delegate = NoOpTranslationDelegate(relaxSyntax: true);
          final resources = {messageKey: templateMessage};
          final results = {
            messageKey: 'JSON: {"enabled": true}. $inventedPluralMessage',
          };

          expect(delegate.validateResults(resources, results), isFalse);
        },
      );

      test(
        'validateResults returns true for resources with valid placeholders',
        () {
          final resources = {
            'key': 'value {count, plural, other{{count} items}}',
            '@key': {
              'placeholders': {
                'count': {
                  'type': 'int',
                },
              },
            },
          };
          final results = {
            'key': 'value {count, plural, other{{count} items}}'
          };

          expect(delegate.validateResults(resources, results), isTrue);
        },
      );

      test(
        'validateResults returns true for a valid select placeholder',
        () {
          final resources = {
            'key': '{gender, select, male{He} female{She} other{They}} replied',
            '@key': {
              'placeholders': {
                'gender': {
                  'type': 'String',
                },
              },
            },
          };
          final results = {
            'key':
                '{gender, select, male{Er} female{Sie} other{Sie}} antwortete',
          };

          expect(delegate.validateResults(resources, results), isTrue);
        },
      );

      test(
        'validateResults returns false for a missing placeholder',
        () {
          final resources = {
            'key': 'Hello {name}',
            '@key': {
              'placeholders': {
                'name': {
                  'type': 'String',
                },
              },
            },
          };
          final results = {'key': 'Hallo'};

          expect(delegate.validateResults(resources, results), isFalse);
        },
      );

      test(
        'validateResults returns false for resources with invalid placeholders',
        () {
          final resources = {
            'key': 'value {count, plural, one{1 item} other{{count} items}}',
            '@key': {
              'placeholders': {
                'count': {
                  'type': 'int',
                },
              },
            },
          };
          final results = {'key': 'value {count, plural, one{item item}}'};

          expect(delegate.validateResults(resources, results), isFalse);
        },
      );

      test(
        'retries and reports locale, key, and invented placeholder',
        () async {
          final delegate = StubTranslationDelegate(
            json.encode({messageKey: inventedPluralMessage}),
          );

          await expectLater(
            delegate.translate(
              {messageKey: templateMessage},
              LocaleInfo.fromString('en_GB'),
            ),
            throwsA(
              isA<PlaceholderValidationException>()
                  .having(
                    (error) => error.message,
                    'message',
                    contains('en_GB'),
                  )
                  .having(
                    (error) => error.message,
                    'message',
                    contains(messageKey),
                  )
                  .having(
                    (error) => error.message,
                    'message',
                    contains('count'),
                  ),
            ),
          );
          expect(delegate.requestCount, 2);
        },
      );

      test(
        'retries and reports a missing placeholder',
        () async {
          final delegate = StubTranslationDelegate(
            json.encode({'key': 'Hallo'}),
          );

          await expectLater(
            delegate.translate(
              {
                'key': 'Hello {name}',
                '@key': {
                  'placeholders': {
                    'name': {
                      'type': 'String',
                    },
                  },
                },
              },
              LocaleInfo.fromString('de'),
            ),
            throwsA(
              isA<PlaceholderValidationException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('de'),
                  contains('"key"'),
                  contains('"name"'),
                ),
              ),
            ),
          );
          expect(delegate.requestCount, 2);
        },
      );

      test(
        'does not write an invented placeholder to an ARB file',
        () async {
          final fileSystem = LocalFileSystem();
          final directory = await fileSystem.systemTempDirectory.createTemp(
            'arb_translate_placeholder_validation_',
          );
          addTearDown(() => directory.delete(recursive: true));

          final templateFile = directory.childFile('app_en.arb');
          final translatedFile = directory.childFile('app_en_GB.arb');
          final originalTranslatedBundle = json.encode({
            '@@locale': 'en_GB',
          });
          await templateFile.writeAsString(
            json.encode({
              '@@locale': 'en',
              messageKey: templateMessage,
            }),
          );
          await translatedFile.writeAsString(originalTranslatedBundle);

          final templateBundle = AppResourceBundle(templateFile);
          final translatedBundle = AppResourceBundle(translatedFile);
          final delegate = StubTranslationDelegate(
            json.encode({messageKey: inventedPluralMessage}),
          );

          await expectLater(
            delegate
                .translate(
                  {messageKey: templateMessage},
                  LocaleInfo.fromString('en_GB'),
                )
                .then(
                  (result) => writeUpdatedBundle(
                    translatedBundle,
                    templateBundle,
                    result,
                  ),
                ),
            throwsA(isA<PlaceholderValidationException>()),
          );
          expect(
            await translatedFile.readAsString(),
            originalTranslatedBundle,
          );
        },
      );
    },
  );
}
