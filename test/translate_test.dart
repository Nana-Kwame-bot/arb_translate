import 'dart:async';
import 'dart:convert';

import 'package:arb_translate/arb_translate.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  test('translate prints the selected model before processing bundles', () async {
    final fileSystem = MemoryFileSystem();
    final arbDirectory = fileSystem.directory('lib/l10n')..createSync(
      recursive: true,
    );
    arbDirectory.childFile('app_en.arb').writeAsStringSync(
      json.encode({'hello': 'Hello'}),
    );
    arbDirectory.childFile('app_de.arb').writeAsStringSync(
      json.encode({'hello': 'Hallo'}),
    );
    final output = <String>[];

    await runZoned(
      () => translate(
        fileSystem,
        const TranslateOptions(
          modelProvider: ModelProvider.gemini,
          model: Model.gemini31FlashLite,
          customModel: null,
          apiKey: 'apiKey',
          vertexAiProjectUrl: null,
          customModelProviderBaseUrl: null,
          disableSafety: false,
          context: null,
          arbDir: 'lib/l10n',
          templateArbFile: 'app_en.arb',
          excludeLocales: null,
          batchSize: 4096,
          useEscaping: false,
          relaxSyntax: false,
        ),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => output.add(line),
      ),
    );

    expect(output.first, 'Using model: gemini-3.1-flash-lite');
  });
}
