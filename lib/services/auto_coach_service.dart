import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:g1_extended/services/assistant_service.dart';
import 'package:g1_extended/services/bluetooth_manager.dart';
import 'package:g1_extended/services/bluetooth_reciever.dart';
import 'package:g1_extended/services/speech_recognition_service.dart';
import 'package:g1_extended/utils/lc3.dart';

/// One heard line, with the time it was heard and who probably said it.
///
/// The speaker tag comes from loudness alone and is therefore a guess: the
/// wearer's voice reaches the temple microphones across a few centimetres, the
/// room's arrives across the table, and that difference is most of what there
/// is to go on. `?` is a real answer - a wrong "they said this" is exactly the
/// kind of error that produces a confident answer to the wrong question.
class HeardLine {
  final String text;
  final DateTime at;

  /// `me`, `them`, or `?` when the level was too close to call.
  final String who;

  const HeardLine(this.text, this.at, {this.who = '?'});

  Map<String, dynamic> toJson() => {'who': who, 'text': text};
}

/// Where the coach listens.
enum CoachCapture {
  /// The glasses' own microphones. Hears the room from the wearer's head and
  /// keeps working with the phone in a pocket; transcribed on the device by
  /// Vosk, which is why it needs the offline model downloaded.
  glasses,

  /// The phone's microphone through the platform recogniser: better on one
  /// clean voice, but it hears a meeting through a pocket and goes silent the
  /// moment the phone is put away.
  phone,
}

/// Guesses the speaker from how loud the line was.
///
/// The reference is the loudest recent utterance, on the argument that the
/// wearer is the person closest to their own microphones: in a room where they
/// speak at all, their lines sit at the top of the distribution. Every line is
/// judged against that peak, which decays slowly so a room that has gone quiet
/// stops pinning the reference.
///
/// This is a heuristic and it is meant to be tuned from the settings card,
/// which shows the level of each line and the tag it earned.
class SpeakerTagger {
  SpeakerTagger({
    this.meMarginDb = 6.0,
    this.roomMarginDb = 12.0,
    this.decayDb = 1.0,
    this.floorDb = -55.0,
  });

  /// Within this much of the peak, the line is the wearer's.
  final double meMarginDb;

  /// This far below the peak, it is the room's.
  final double roomMarginDb;

  /// How much the peak forgets between lines.
  final double decayDb;

  /// Below this, nothing was said: silence and handling noise are not speech.
  final double floorDb;

  double _peakDb = double.negativeInfinity;

  double get peakDb => _peakDb;

  /// Tags one utterance, and updates the reference with it.
  String tag(double utteranceDb) {
    if (utteranceDb <= floorDb || utteranceDb.isNaN) return '?';

    if (_peakDb.isInfinite) {
      // The first voice heard sets the reference, and gets no tag: at that
      // point there is nothing to compare it against.
      _peakDb = utteranceDb;
      return '?';
    }

    final delta = utteranceDb - _peakDb;
    _peakDb = utteranceDb > _peakDb ? utteranceDb : _peakDb - decayDb;

    if (delta >= -meMarginDb) return 'me';
    if (delta <= -roomMarginDb) return 'them';
    return '?';
  }
}

/// Root-mean-square level of the audio between two utterances.
///
/// Kept deliberately dumb: one sum of squares over the samples fed since the
/// last utterance ended. The recogniser finalises on silence, so that span is
/// the utterance almost exactly.
class LevelMeter {
  double _sumSquares = 0;
  int _samples = 0;

  void observe(List<int> pcm16) {
    for (int i = 0; i + 1 < pcm16.length; i += 2) {
      var sample = (pcm16[i] & 0xff) | (pcm16[i + 1] << 8);
      if (sample >= 0x8000) sample -= 0x10000; // signed 16-bit
      _sumSquares += (sample * sample).toDouble();
      _samples++;
    }
  }

  /// Mean level in dBFS, or [double.negativeInfinity] when nothing was fed.
  double get db {
    if (_samples == 0) return double.negativeInfinity;
    final rms = math.sqrt(_sumSquares / _samples);
    return rms <= 0 ? -120.0 : 20 * (math.log(rms / 32768) / math.ln10);
  }

  void reset() {
    _sumSquares = 0;
    _samples = 0;
  }
}

/// Listens continuously and puts a line on the lens when one is warranted.
///
/// This is the hands-free counterpart to [AssistantService]. That one waits to
/// be asked. This one keeps its own rolling window of what was just said and
/// asks the coach after every utterance, letting the coach decide whether
/// anything is needed at all - which is why nothing is tapped, and why the
/// model's "nothing needed" answer never reaches the lens.
///
/// Two deliberate limits:
///
/// * The window is short. A coach answering from a transcript of one sentence
///   misses the thread; a coach carrying the whole meeting sends a few thousand
///   tokens every few seconds and answers slowly enough to be useless.
/// * Firing is rate-limited on the server, not here, so the phone cannot hammer
///   the endpoint by looping faster than the wearer can read.
class AutoCoachService {
  AutoCoachService._internal();
  static final AutoCoachService singleton = AutoCoachService._internal();
  factory AutoCoachService() => singleton;

  static const _enabledKey = 'coach_auto_enabled';
  static const _urlKey = 'coach_auto_url';
  static const _localeKey = 'coach_auto_locale';
  static const _captureKey = 'coach_capture';

  /// How often the glasses' audio buffer is drained and decoded.
  ///
  /// Short enough that the recogniser sees the audio as it is spoken, long
  /// enough that decoding a 10 ms frame batch is not the phone's whole
  /// afternoon. The recogniser, not this, decides where an utterance ends.
  static const Duration drainInterval = Duration(milliseconds: 250);

  /// How many lines of context travel with each request. Enough to carry a
  /// question and the answer to it, short enough to stay fast and cheap.
  static const int windowLines = 6;

  /// Same ceiling the lens can hold; the coach is told 150, this is the net
  /// for when it forgets.
  static const int maxLensChars = 220;

  /// Utterances shorter than this are noise: "hmm", "yes", a cough. Sending
  /// them costs a request each and invites the coach to answer nothing.
  static const int minWords = 3;

  /// How long one capture runs before the recogniser hands back what it heard.
  static const Duration captureWindow = Duration(seconds: 12);

  /// Indian English by default: this is a Bengali-accented English user, and
  /// the platform default is useless for that. Bengali itself is a deliberate
  /// switch, not automatic - one locale at a time is all a recogniser offers,
  /// so flipping to bn-IN costs the English.
  static const String defaultLocale = 'en_IN';

  final SpeechRecognitionService _speech = SpeechRecognitionService.singleton;
  final BluetoothManager _bluetooth = BluetoothManager.singleton;
  final AssistantService _assistant = AssistantService.singleton;

  final List<HeardLine> _window = [];
  bool _running = false;
  bool _stopRequested = false;
  String _lastShown = '';
  int _consecutiveFailures = 0;
  DateTime _lastFailureAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// What the settings screen shows, because everything this service does is
  /// otherwise invisible: a coach that hears nothing, a coach that declines
  /// every line, and a lens write that fails all look the same from the sofa -
  /// a blank lens with no way to tell which of the three it was.
  String _lastHeard = '';
  String _lastLine = '';
  String _lastOutcome = 'nothing yet';

  /// The source actually capturing right now, and the tag the last line earned
  /// with the level it earned it at. Shown on the settings card so the speaker
  /// heuristic can be judged against real rooms rather than argued about.
  CoachCapture? _captureActive;
  String _lastTag = '?';
  double _lastLevelDb = double.negativeInfinity;

  final SpeakerTagger _tagger = SpeakerTagger();
  final LevelMeter _meter = LevelMeter();

  final StreamController<HeardLine> _heardController =
      StreamController<HeardLine>.broadcast();
  final StreamController<String> _coachController =
      StreamController<String>.broadcast();

  bool get isRunning => _running;
  Stream<HeardLine> get heard => _heardController.stream;
  Stream<String> get coached => _coachController.stream;
  List<HeardLine> get window => List.unmodifiable(_window);

  /// The last utterance that was long enough to send, and what became of it.
  /// Read by the settings screen; see [_lastHeard].
  String get lastHeard => _lastHeard;

  /// The last line that reached the lens, or the last line the coach produced
  /// and could not put there.
  String get lastLine => _lastLine;

  /// One phrase for where the last utterance ended up: on the lens, held back by
  /// the coach and why, or lost between the phone and the glasses.
  String get lastOutcome => _lastOutcome;

  /// Which microphone is feeding the coach right now, or null when it is idle.
  CoachCapture? get captureActive => _captureActive;

  /// The tag the last heard line earned, and the level it earned it at.
  String get lastTag => _lastTag;

  double get lastLevelDb => _lastLevelDb;

  /// Where the coach listens, when it has the choice.
  Future<CoachCapture> capture() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_captureKey) ?? CoachCapture.glasses.name;
    return CoachCapture.values.firstWhere(
      (c) => c.name == stored,
      orElse: () => CoachCapture.glasses,
    );
  }

  Future<void> setCapture(CoachCapture value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_captureKey, value.name);

    // Restart rather than swap underneath the running loop: one microphone has
    // to be closed before the other opens, or both are open at once.
    if (_running) {
      await stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      unawaited(start());
    }
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    if (enabled) {
      unawaited(start());
    } else {
      await stop();
    }
  }

  /// Called at boot. Listening survives a restart only if the wearer left it
  /// on - an app that starts the microphone by itself after an update is a
  /// nasty surprise, and on a phone in a pocket nobody would notice.
  ///
  /// The listen loop is deliberately not awaited. [start] runs until it is
  /// stopped, so awaiting it here hung whoever called it - and at boot the
  /// caller is `main`, which never reached `runApp`. The symptom was a black
  /// screen with no error and no log: the app was alive and listening, with no
  /// interface to prove it.
  Future<void> resumeIfEnabled() async {
    if (await isEnabled()) unawaited(start());
  }

  Future<String> locale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_localeKey) ?? defaultLocale;
  }

  Future<void> setLocale(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, value.trim());
  }

  /// Where the coach lives. Unset means "the assistant's host": the coach is
  /// served from the same place, so pointing at it once is enough.
  Future<String> endpoint() async {
    final prefs = await SharedPreferences.getInstance();
    final own = prefs.getString(_urlKey)?.trim() ?? '';
    if (own.isNotEmpty) return own;
    return autoUrlFor(await _assistant.baseUrl());
  }

  Future<void> setEndpoint(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, value.trim());
  }

  /// Resolves the auto-coach URL from whatever the user typed for the
  /// assistant. Accepts the host, the host with /coach, or the full path.
  @visibleForTesting
  static String autoUrlFor(String input) {
    var text = input.trim();
    if (text.isEmpty) return '';
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('/coach/auto') || text.endsWith('/auto')) return text;
    if (text.endsWith('/coach')) return '$text/auto';
    if (text.endsWith('/v1')) text = text.substring(0, text.length - 3);
    return '$text/coach/auto';
  }

  /// True when a heard line is worth spending a request on.
  @visibleForTesting
  static bool isWorthSending(String text) {
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.length >= minWords;
  }

  @visibleForTesting
  static List<HeardLine> trim(List<HeardLine> lines) {
    if (lines.length <= windowLines) return List.of(lines);
    return lines.sublist(lines.length - windowLines);
  }

  /// Runs until stopped. Safe to call twice; the second call is a no-op.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _stopRequested = false;

    final chosen = await capture();

    try {
      if (chosen == CoachCapture.glasses && _bluetooth.isConnected) {
        try {
          await _listenThroughGlasses();
        } catch (e) {
          // A missing offline model is a configuration problem, not a reason to
          // sit in silence: the phone recogniser needs nothing downloaded, so
          // the sitting carries on with the worse microphone and says so.
          debugPrint('AutoCoachService: glasses capture failed: $e');
          _lastOutcome = 'glasses capture failed, using the phone: $e';
          if (!_stopRequested) await _listenThroughPhone();
        }
      } else {
        if (chosen == CoachCapture.glasses) {
          _lastOutcome = 'glasses not connected - listening on the phone';
        }
        await _listenThroughPhone();
      }
    } catch (e) {
      debugPrint('AutoCoachService: capture failed: $e');
      _lastOutcome = 'capture failed: $e';
    }

    _captureActive = null;
    _running = false;
    debugPrint('AutoCoachService: stopped');
  }

  /// Listens through the glasses' own microphones.
  ///
  /// The glasses stream LC3 frames from their microphones over BLE; the app
  /// collects them, decodes to 16 kHz PCM and feeds Vosk on the device. This is
  /// the microphone that hears the room the wearer is standing in rather than
  /// the inside of their pocket, and it is the only one that can say anything
  /// about who spoke, because it can measure how loudly each line arrived.
  ///
  /// The recogniser, not a timer, decides where an utterance ends: Vosk
  /// finalises after roughly half a second of silence, which is the endpoint
  /// debounce a line-at-a-time coach needs.
  Future<void> _listenThroughGlasses() async {
    final collector = BluetoothReciever.singleton.voiceCollector;
    final live = await _speech.startLiveTranscription();
    final pending = <String>[];
    final subscription = live.sentences.listen(pending.add);

    _captureActive = CoachCapture.glasses;
    _lastOutcome = 'listening on the glasses';
    debugPrint('AutoCoachService: listening on the glasses microphone');

    try {
      collector.reset();
      collector.isRecording = true;
      await _bluetooth.setMicrophone(true);

      while (!_stopRequested) {
        await Future<void>.delayed(drainInterval);

        final encoded = await collector.getAllDataAndReset();
        if (encoded.isEmpty) continue;

        final pcm = await LC3.decodeLC3(Uint8List.fromList(encoded));
        if (pcm.isEmpty) continue;

        _meter.observe(pcm);
        await live.feed(pcm);

        while (pending.isNotEmpty && !_stopRequested) {
          final text = pending.removeAt(0);
          final db = _meter.db;
          _meter.reset();
          if (!isWorthSending(text)) continue;

          final tag = _tagger.tag(db);
          _lastTag = tag;
          _lastLevelDb = db;
          await _recordLine(HeardLine(text.trim(), DateTime.now(), who: tag));
        }
      }
    } finally {
      collector.isRecording = false;
      await subscription.cancel();
      await live.close();
      try {
        await _bluetooth.setMicrophone(false);
      } catch (e) {
        debugPrint('AutoCoachService: could not close the glasses mic: $e');
      }
    }
  }

  /// Listens through the phone's microphone, on the platform recogniser.
  Future<void> _listenThroughPhone() async {
    _captureActive = CoachCapture.phone;
    if (_lastOutcome == 'nothing yet') _lastOutcome = 'listening on the phone';
    debugPrint('AutoCoachService: listening on the phone microphone');

    final chosenLocale = await locale();

    while (!_stopRequested) {
      try {
        final heard = await _speech.listenOnPhone(
          timeout: captureWindow,
          localeId: chosenLocale,
        );
        if (_stopRequested) break;
        if (heard == null || !isWorthSending(heard)) continue;

        // The platform recogniser reports no level and knows nothing about who
        // was speaking, so every line from this path stays untagged.
        _lastTag = '?';
        _lastLevelDb = double.negativeInfinity;
        await _recordLine(HeardLine(heard.trim(), DateTime.now()));
      } catch (e) {
        // A recogniser that refuses (no permission, no network for a locale)
        // must not spin: pause, then try again.
        debugPrint('AutoCoachService: capture failed: $e');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  /// Adds a heard line to the window and asks the coach about it.
  Future<void> _recordLine(HeardLine line) async {
    _lastHeard = line.text;
    _window.add(line);
    final trimmed = trim(_window);
    _window
      ..clear()
      ..addAll(trimmed);
    if (!_heardController.isClosed) _heardController.add(line);
    await _ask();
  }

  Future<void> stop() async {
    _stopRequested = true;
    await _speech.stopListening();
    _running = false;
  }

  void clearWindow() => _window.clear();

  Future<void> _ask() async {
    final url = await endpoint();
    if (url.isEmpty) {
      _lastOutcome = 'no coach URL set';
      return;
    }

    // Failures back off: a coach endpoint that is down, or a phone with no
    // signal, should not be retried once per utterance forever.
    final sinceFailure = DateTime.now().difference(_lastFailureAt);
    final backoff = Duration(seconds: (5 * _consecutiveFailures).clamp(0, 60));
    if (_consecutiveFailures > 0 && sinceFailure < backoff) {
      _lastOutcome = 'waiting: endpoint failed $_consecutiveFailures time(s)';
      return;
    }

    final key = await _assistant.apiKey();

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'window': _window.map((l) => l.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _lastOutcome = 'endpoint returned ${response.statusCode}';
        _recordFailure('endpoint returned ${response.statusCode}');
        return;
      }

      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) {
        _lastOutcome = 'unexpected reply';
        _recordFailure('unexpected reply');
        return;
      }

      _consecutiveFailures = 0;

      final say = (body['say'] ?? '') as String;
      if (body['fired'] != true || say.trim().isEmpty) {
        // Silence is the normal case, and the reason matters: the coach
        // declining a line it was not asked is the feature working, not a
        // fault, and telling the two apart is what the screen is for.
        final why = (body['skipped'] ?? 'nothing needed') as Object;
        _lastOutcome = 'held back by the coach: $why';
        return;
      }
      if (say.trim() == _lastShown) {
        _lastOutcome = 'held back: same line as last time';
        return; // the same line twice is noise
      }

      _lastShown = say.trim();
      _lastLine = _lastShown;
      if (!_coachController.isClosed) _coachController.add(_lastShown);

      try {
        // The write reports whether both temples took it. That is the only
        // honest answer to "why is the lens blank?": the coach answering and
        // the glasses not listening look exactly alike from the outside.
        final reached = await _bluetooth.sendPriorityText(lensText(_lastShown));
        _lastOutcome = reached
            ? 'on the lens'
            : 'lens write failed - are the glasses connected?';
      } catch (e) {
        _lastOutcome = 'lens write threw: $e';
        debugPrint('AutoCoachService: could not reach the lens: $e');
      }
    } catch (e) {
      _lastOutcome = 'request failed: $e';
      _recordFailure(e.toString());
    }
  }

  void _recordFailure(String reason) {
    _consecutiveFailures++;
    _lastFailureAt = DateTime.now();
    debugPrint('AutoCoachService: $reason (failure $_consecutiveFailures)');
  }

  /// Clamps the line to what the lens can hold. The coach is told 150
  /// characters and normally obeys; this is the net for when it does not.
  @visibleForTesting
  static String lensText(String line) {
    if (line.length <= maxLensChars) return line;
    return '${line.substring(0, maxLensChars - 1).trimRight()}\u2026';
  }
}
