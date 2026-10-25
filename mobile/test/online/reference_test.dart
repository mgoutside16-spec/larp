import 'package:flutter_test/flutter_test.dart';
import 'package:larp_player/core/models.dart';
import 'package:larp_player/core/update_client.dart';

void main() {
  const id = '11111111-1111-4111-8111-111111111111';
  test('accepts a game UUID or the known workshop share link', () {
    expect(parseGameReference(id.toUpperCase()), id);
    expect(
      parseGameReference('https://mgoutside16-spec.github.io/larp/?game=$id'),
      id,
    );
  });
  test(
    'rejects arbitrary sites, incomplete codes and ambiguous links in Russian',
    () {
      for (final input in [
        '12345',
        'https://external.test/?game=$id',
        'https://mgoutside16-spec.github.io/other/?game=$id',
        'https://mgoutside16-spec.github.io/larp/?game=$id&game=$id',
      ]) {
        expect(
          () => parseGameReference(input),
          throwsA(isA<PlayerException>()),
        );
      }
    },
  );
}
