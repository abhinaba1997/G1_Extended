import 'package:flutter_test/flutter_test.dart';
import 'package:g1_extended/services/auto_coach_service.dart';

/// These are the parts of the coach that can be wrong in a way the wearer
/// cannot see: a URL that quietly 404s, a window that carries the wrong
/// context, or a line that would overflow the lens. The listening itself can
/// only be checked on a real phone.
void main() {
  group('autoUrlFor', () {
    test('adds the coach path to a bare host', () {
      expect(
        AutoCoachService.autoUrlFor('https://bob-server.tail603ac8.ts.net'),
        'https://bob-server.tail603ac8.ts.net/coach/auto',
      );
    });

    test('appends to a host that already carries /coach', () {
      expect(
        AutoCoachService.autoUrlFor('https://bob-server.tail603ac8.ts.net/coach'),
        'https://bob-server.tail603ac8.ts.net/coach/auto',
      );
    });

    test('tolerates a trailing slash', () {
      expect(
        AutoCoachService.autoUrlFor('https://bob-server.tail603ac8.ts.net/coach/'),
        'https://bob-server.tail603ac8.ts.net/coach/auto',
      );
    });

    test('leaves a full coach URL alone', () {
      const url = 'https://bob-server.tail603ac8.ts.net/coach/auto';
      expect(AutoCoachService.autoUrlFor(url), url);
    });

    test('drops a /v1 that belonged to the chat-completions path', () {
      expect(
        AutoCoachService.autoUrlFor('https://bob-server.tail603ac8.ts.net/v1'),
        'https://bob-server.tail603ac8.ts.net/coach/auto',
      );
    });

    test('returns nothing when nothing was configured', () {
      expect(AutoCoachService.autoUrlFor('   '), '');
    });
  });

  group('isWorthSending', () {
    test('ignores one and two word utterances', () {
      expect(AutoCoachService.isWorthSending('yes'), isFalse);
      expect(AutoCoachService.isWorthSending('hmm okay'), isFalse);
      expect(AutoCoachService.isWorthSending('   '), isFalse);
    });

    test('sends a real sentence', () {
      expect(
        AutoCoachService.isWorthSending('where is the three crore then'),
        isTrue,
      );
    });

    test('counts words, not spaces', () {
      expect(AutoCoachService.isWorthSending('  a   b   c  '), isTrue);
    });
  });

  group('trim', () {
    test('keeps everything shorter than the window', () {
      final lines = [
        HeardLine('one two three', DateTime(2026, 9, 23)),
        HeardLine('four five six', DateTime(2026, 9, 23)),
      ];
      expect(AutoCoachService.trim(lines).length, 2);
    });

    test('keeps the newest lines and drops the oldest', () {
      final lines = [
        for (var i = 0; i < 9; i++)
          HeardLine('line number $i', DateTime(2026, 9, 23)),
      ];
      final kept = AutoCoachService.trim(lines);
      expect(kept.length, AutoCoachService.windowLines);
      expect(kept.first.text, 'line number 3');
      expect(kept.last.text, 'line number 8');
    });

    test('does not mutate the list it was given', () {
      final lines = [
        for (var i = 0; i < 9; i++)
          HeardLine('line number $i', DateTime(2026, 9, 23)),
      ];
      AutoCoachService.trim(lines);
      expect(lines.length, 9);
    });
  });

  group('lensText', () {
    test('passes a short line straight through', () {
      expect(AutoCoachService.lensText('That is answered by counsel.'),
          'That is answered by counsel.');
    });

    test('clamps a long line to what the lens can hold', () {
      final long = 'word ' * 100;
      final clamped = AutoCoachService.lensText(long);
      expect(clamped.length, AutoCoachService.maxLensChars);
      expect(clamped.endsWith('\u2026'), isTrue);
    });
  });
}
