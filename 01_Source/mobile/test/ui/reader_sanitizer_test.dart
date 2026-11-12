import 'package:flutter_test/flutter_test.dart';
import 'package:larp_player/ui/record_reader.dart';

void main() {
  test(
    'master browser Enter paragraphs and styled emphasis retain their meaning',
    () {
      expect(
        safePlayerHtml(
          '<div>Первая строка</div><div><span style="font-weight: 700; font-style: italic; color: red" onclick="bad()">Вторая строка</span></div>',
        ),
        '<p>Первая строка</p><p><b><i>Вторая строка</i></b></p>',
      );
    },
  );

  test(
    'reader preserves paragraphs and emphasis without external resources',
    () {
      final text = safePlayerHtml(
        '<h2 onclick="bad()">Сон</h2><p>Тихое <b>море</b> <i>ночью</i>.</p>'
        '<script>bad()</script><img src="https://example.org/secret"><video src="https://example.org/movie"></video>'
        '<a href="https://example.org/">Берег</a><iframe>hidden</iframe>',
      );
      expect(text, '<h2>Сон</h2><p>Тихое <b>море</b> <i>ночью</i>.</p>Берег');
    },
  );

  test(
    'reader escapes text instead of reinterpreting escaped active markup',
    () {
      expect(
        safePlayerHtml('<p>&lt;img src=x onerror=bad()&gt; &amp; море</p>'),
        '<p>&lt;img src=x onerror=bad()&gt; &amp; море</p>',
      );
    },
  );
}
