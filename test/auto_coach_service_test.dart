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

  group('SpeakerTagger', () {
    test('gives the first voice a reference but no tag', () {
      final tagger = SpeakerTagger();
      expect(tagger.tag(-30), '?');
      expect(tagger.peakDb, -30);
    });

    test('calls a line close to the peak the wearer', () {
      final tagger = SpeakerTagger()..tag(-30);
      expect(tagger.tag(-33), 'me');
    });

    test('calls a much quieter line the room', () {
      final tagger = SpeakerTagger()..tag(-30);
      expect(tagger.tag(-45), 'them');
    });

    test('admits it cannot tell when the level sits between the two', () {
      final tagger = SpeakerTagger()..tag(-30);
      expect(tagger.tag(-38), '?');
    });

    test('ignores silence rather than tagging it', () {
      final tagger = SpeakerTagger();
      expect(tagger.tag(-80), '?');
      expect(tagger.peakDb.isInfinite, isTrue);
    });

    test('a louder line becomes the new reference', () {
      final tagger = SpeakerTagger()..tag(-40);
      expect(tagger.tag(-30), 'me');
      expect(tagger.peakDb, -30);
    });

    test('the reference decays so a quiet room stops pinning it', () {
      final tagger = SpeakerTagger(decayDb: 2)..tag(-30);
      tagger.tag(-45); // the room, and the peak forgets two decibels
      expect(tagger.peakDb, -32);
    });
  });

  group('LevelMeter', () {
    test('reports silence as very quiet', () {
      final meter = LevelMeter()..observe([0, 0, 0, 0]);
      expect(meter.db, lessThan(-100));
    });

    test('reads little-endian samples', () {
      // 1000 as a signed 16-bit little-endian sample: 0x03e8.
      final meter = LevelMeter()..observe([0xe8, 0x03]);
      expect(meter.db, closeTo(-30.3, 0.1));
    });

    test('reports full scale as about zero', () {
      final meter = LevelMeter()..observe([0xff, 0x7f, 0xff, 0x7f]);
      expect(meter.db, closeTo(0, 0.1));
    });

    test('says nothing when nothing was fed', () {
      expect(LevelMeter().db.isInfinite, isTrue);
    });

    test('resets between utterances', () {
      final meter = LevelMeter()..observe([0xff, 0x7f]);
      meter.reset();
      expect(meter.db.isInfinite, isTrue);
    });
  });

  group('HeardLine', () {
    test('carries the speaker tag to the coach', () {
      final line = HeardLine('where is the money', DateTime(2026, 9, 27),
          who: 'them');
      expect(line.toJson(), {'who': 'them', 'text': 'where is the money'});
    });

    test('defaults to untagged rather than guessing', () {
      expect(HeardLine('something said', DateTime(2026, 9, 27)).who, '?');
    });
  });
}
