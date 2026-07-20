import 'dart:convert';

import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle.dart';
import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle_collection.dart';
import 'package:arb_translate/src/flutter_tools/gen_l10n_types.dart';
import 'package:arb_translate/src/flutter_tools/localizations_utils.dart';
import 'package:arb_translate/src/flutter_tools/message_parser.dart';
import 'package:arb_translate/src/translation_delegates/translate_exception.dart';
import 'package:meta/meta.dart';

abstract class TranslationDelegate {
  static final _icuControlExpressionStart = RegExp(
    r'\{\s*[a-zA-Z0-9|_]+\s*,\s*(?:plural|select|date|time)\b',
  );

  const TranslationDelegate({
    required this.batchSize,
    required this.context,
    required this.useEscaping,
    required this.relaxSyntax,
  });

  final int batchSize;
  final String? context;
  final bool useEscaping;
  final bool relaxSyntax;

  int get maxRetryCount;
  int get maxParallelQueries;
  Duration get queryBackoff;

  Future<Map<String, String>> translate(
    Map<String, Object?> resources,
    LocaleInfo locale,
  ) async {
    final batches = prepareBatches(resources);

    final results = <String, String>{};

    for (var i = 0; i < batches.length; i += maxParallelQueries) {
      final batchResults = await Future.wait([
        for (var j = i; j < i + maxParallelQueries && j < batches.length; j++)
          _translateBatch(
            resources: batches[j],
            locale: locale,
            batchName: '${j + 1}/${batches.length}',
          ),
      ]);

      results.addAll({for (final results in batchResults) ...results});
    }

    return results;
  }

  List<Map<String, Object?>> prepareBatches(Map<String, Object?> resources) {
    final batches = [<String, Object?>{}];

    var lastBatchSize = 0;

    for (final key in resources.keys.where((key) => !key.startsWith('@'))) {
      final resourceWithMetadata = {
        key: resources[key],
        if (resources.containsKey('@$key')) '@$key': resources['@$key'],
      };
      final resourceSize = json.encode(resourceWithMetadata).length;

      if (lastBatchSize == 0 || lastBatchSize + resourceSize <= batchSize) {
        batches.last.addAll(resourceWithMetadata);

        lastBatchSize += resourceSize;
      } else {
        batches.add(resourceWithMetadata);

        lastBatchSize = resourceSize;
      }
    }

    return batches;
  }

  Future<Map<String, String>> _translateBatch({
    required Map<String, Object?> resources,
    required LocaleInfo locale,
    required String batchName,
  }) async {
    var retryCount = 0;

    while (true) {
      String response;

      try {
        response = await getModelResponse(resources, locale);
      } on QuotaExceededException {
        print(
          'Quota exceeded for batch $batchName, retrying in '
          '${queryBackoff.inSeconds}s...',
        );

        await Future.delayed(queryBackoff);
        continue;
      } on NoResponseException catch (_) {
        retryCount++;

        print(
          'Placeholder validation failed for batch $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        if (retryCount > maxRetryCount) {
          rethrow;
        }

        continue;
      }

      final result = _tryParseResponse(resources, response);

      if (result == null) {
        retryCount++;

        if (retryCount > maxRetryCount) {
          throw ResponseParsingException();
        }

        print(
          'Failed to parse response for $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        continue;
      }

      final validationFailure = _validateResults(resources, result);

      if (validationFailure != null) {
        retryCount++;

        print(
          'Placeholder validation failed for batch $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        if (retryCount > maxRetryCount) {
          throw PlaceholderValidationException(
            locale: locale.toString(),
            messageKey: validationFailure.messageKey,
            details: validationFailure.details,
          );
        }

        continue;
      }

      print('Translated batch $batchName');

      return result;
    }
  }

  Future<String> getModelResponse(
    Map<String, Object?> resources,
    LocaleInfo locale,
  );

  Map<String, String>? _tryParseResponse(
    Map<String, Object?> resources,
    String? response,
  ) {
    if (response == null) {
      return null;
    }

    final trimmedResponse = response.substring(
      response.indexOf('{'),
      response.lastIndexOf('}') + 1,
    );

    Map<String, Object?> responseJson;

    try {
      responseJson = json.decode(trimmedResponse);
    } catch (e) {
      return null;
    }

    final messageResources = resources.keys.where(
      (key) => !key.startsWith('@'),
    );

    if (messageResources.any((key) => responseJson[key] is! String)) {
      return null;
    }

    return {
      for (final key in messageResources) key: responseJson[key] as String,
    };
  }

  @protected
  @visibleForTesting
  bool validateResults(
    Map<String, Object?> resources,
    Map<String, String> results,
  ) =>
      _validateResults(resources, results) == null;

  _PlaceholderValidationFailure? _validateResults(
    Map<String, Object?> resources,
    Map<String, String> results,
  ) {
    final templateBundle = FakeAppResourcesBundle(resources, true);
    final otherBundle = FakeAppResourcesBundle(results, false);

    for (final key in resources.keys.where((key) => !key.startsWith('@'))) {
      try {
        final message = Message(
          templateBundle,
          FakeAppResourceBundleCollection(
            templateBundle: templateBundle,
            otherBundle: otherBundle,
          ),
          key,
          false,
          useEscaping: useEscaping,
          useRelaxedSyntax: relaxSyntax,
        );

        if (message.hadErrors) {
          return _PlaceholderValidationFailure(messageKey: key);
        }

        final templatePlaceholders = _declaredPlaceholders(resources, key)
          ..addAll(
            _parsedPlaceholders(
              message.parsedMessages[templateBundle.locale],
            ),
          );
        final translatedPlaceholders = _parsedPlaceholders(
          message.parsedMessages[otherBundle.locale],
        );

        if (relaxSyntax) {
          translatedPlaceholders.addAll(
            _relaxedControlPlaceholders(
              key,
              otherBundle.file.basename,
              results[key]!,
            ),
          );
        }

        final missingPlaceholders = templatePlaceholders
            .difference(translatedPlaceholders)
            .toList()
          ..sort();
        final unexpectedPlaceholders = translatedPlaceholders
            .difference(templatePlaceholders)
            .toList()
          ..sort();

        if (missingPlaceholders.isNotEmpty ||
            unexpectedPlaceholders.isNotEmpty) {
          return _PlaceholderValidationFailure(
            messageKey: key,
            missingPlaceholders: missingPlaceholders,
            unexpectedPlaceholders: unexpectedPlaceholders,
          );
        }
      } catch (e) {
        return _PlaceholderValidationFailure(messageKey: key);
      }
    }

    return null;
  }

  Set<String> _declaredPlaceholders(
    Map<String, Object?> resources,
    String key,
  ) {
    final attributes = resources['@$key'];

    if (attributes is! Map<String, Object?>) {
      return <String>{};
    }

    final placeholders = attributes['placeholders'];

    if (placeholders is! Map<String, Object?>) {
      return <String>{};
    }

    return placeholders.keys.toSet();
  }

  Set<String> _parsedPlaceholders(
    Node? root, {
    bool includeSimplePlaceholders = true,
  }) {
    if (root == null) {
      return <String>{};
    }

    final placeholders = <String>{};
    final traversalStack = <Node>[root];

    while (traversalStack.isNotEmpty) {
      final node = traversalStack.removeLast();

      if ((includeSimplePlaceholders && node.type == ST.placeholderExpr) ||
          <ST>{
            ST.pluralExpr,
            ST.selectExpr,
            ST.argumentExpr,
          }.contains(node.type)) {
        placeholders.add(node.children[1].value!);
      }

      traversalStack.addAll(node.children);
    }

    return placeholders;
  }

  Set<String> _relaxedControlPlaceholders(
    String key,
    String filename,
    String message,
  ) {
    final placeholders = <String>{};

    for (final match in _icuControlExpressionStart.allMatches(message)) {
      if (useEscaping && _isWithinQuotedString(message, match.start)) {
        continue;
      }

      var end = message.indexOf('}', match.end);

      while (end != -1) {
        try {
          placeholders.addAll(
            _parsedPlaceholders(
              Parser(
                key,
                filename,
                message.substring(match.start, end + 1),
                useEscaping: useEscaping,
              ).parse(),
              includeSimplePlaceholders: false,
            ),
          );
          break;
        } on L10nException catch (_) {
          end = message.indexOf('}', end + 1);
        }
      }
    }

    return placeholders;
  }

  bool _isWithinQuotedString(String message, int position) {
    var isQuoted = false;

    for (var index = 0; index < position; index++) {
      if (message[index] != "'") {
        continue;
      }

      if (index + 1 < position && message[index + 1] == "'") {
        index++;
      } else {
        isQuoted = !isQuoted;
      }
    }

    return isQuoted;
  }
}

class _PlaceholderValidationFailure {
  const _PlaceholderValidationFailure({
    required this.messageKey,
    this.missingPlaceholders = const [],
    this.unexpectedPlaceholders = const [],
  });

  final String messageKey;
  final List<String> missingPlaceholders;
  final List<String> unexpectedPlaceholders;

  String? get details {
    final failures = <String>[
      if (missingPlaceholders.isNotEmpty)
        'missing ${_describePlaceholders(missingPlaceholders)}',
      if (unexpectedPlaceholders.isNotEmpty)
        'unexpected ${_describePlaceholders(unexpectedPlaceholders)}',
    ];

    return failures.isEmpty ? null : failures.join('; ');
  }

  String _describePlaceholders(List<String> placeholders) {
    final label = placeholders.length == 1 ? 'placeholder' : 'placeholders';
    final names = placeholders.map((name) => '"$name"').join(', ');

    return '$label $names';
  }
}
