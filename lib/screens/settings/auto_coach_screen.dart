import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:g1_extended/services/assistant_service.dart';
import 'package:g1_extended/services/auto_coach_service.dart';

/// Settings for the continuous coach: the mode where nothing is tapped.
///
/// The wording here is deliberately blunt. A screen that switches on a live
/// microphone in someone's pocket should say what that means, and the person
/// reading it should be able to explain it to whoever is sitting opposite.
class AutoCoachScreen extends StatefulWidget {
  const AutoCoachScreen({super.key});

  @override
  State<AutoCoachScreen> createState() => _AutoCoachScreenState();
}

class _AutoCoachScreenState extends State<AutoCoachScreen> {
  final AutoCoachService _coach = AutoCoachService.singleton;
  final AssistantService _assistant = AssistantService.singleton;
  final TextEditingController _localeController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();

  bool _loading = true;
  bool _enabled = false;
  bool _testing = false;
  String _resolvedEndpoint = '';
  String _testResult = '';

  /// Redraws the live card below. Everything this feature does happens out of
  /// sight, so without this a blank lens and a working coach look the same.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _localeController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await _coach.isEnabled();
    final locale = await _coach.locale();
    final endpoint = await _coach.endpoint();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _localeController.text = locale;
      _endpointController.text = endpoint;
      _resolvedEndpoint = endpoint;
      _loading = false;
    });
  }

  Future<void> _setEnabled(bool value) async {
    // Ask for the microphone before switching on: a coach that silently never
    // hears anything is worse than one that says it cannot start.
    await _coach.setEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  Future<void> _save() async {
    await _coach.setLocale(_localeController.text);
    await _coach.setEndpoint(_endpointController.text);
    final endpoint = await _coach.endpoint();
    if (!mounted) return;
    setState(() {
      _endpointController.text = endpoint;
      _resolvedEndpoint = endpoint;
      _testResult = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved.')),
    );
  }

  /// Sends one fixed question and shows whatever comes back, so the endpoint
  /// can be checked from the sofa rather than in the room.
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });

    final url = _resolvedEndpoint;
    if (url.isEmpty) {
      setState(() {
        _testing = false;
        _testResult = 'No endpoint. Set the Assistant server first.';
      });
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
              'window': [
                {
                  'who': '?',
                  'text':
                      'So what is your side actually saying about the letter we sent?',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _testing = false;
          _testResult = 'Endpoint returned ${response.statusCode}.';
        });
        return;
      }

      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final say = (body is Map && body['say'] is String) ? body['say'] as String : '';
      setState(() {
        _testing = false;
        _testResult = say.trim().isEmpty
            ? 'Reached it, but it chose to stay quiet for that line.'
            : say.trim();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = 'Could not reach it: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Coach')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            value: _enabled,
            onChanged: _setEnabled,
            title: const Text('Listen continuously'),
            subtitle: const Text(
              'The phone keeps the microphone open and sends the last few '
              'lines to your coach after each one. Nothing is tapped.',
            ),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Read this before leaving it on',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    'The microphone does not know who is speaking. Anyone in '
                    'the room is transcribed, and the last few lines are sent '
                    'to your coach server each time. It is off by default and '
                    'off again when you flip the switch.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _localeController,
            decoration: const InputDecoration(
              labelText: 'Recognition language',
              helperText:
                  'en_IN for Indian English. Switch to bn-IN only when the '
                  'other side is speaking Bengali - a recogniser handles one '
                  'language at a time, so the English goes with it.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          // Bengali is offered as a shortcut because it is the case that
          // prompted this screen; any other locale can still be typed in.
          Wrap(
            spacing: 8,
            children: [
              for (final entry in const [
                ('en_IN', 'Indian English'),
                ('bn-IN', 'Bengali'),
                ('en-US', 'US English'),
              ])
                ActionChip(
                  label: Text(entry.$2),
                  onPressed: () =>
                      setState(() => _localeController.text = entry.$1),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _endpointController,
            decoration: const InputDecoration(
              labelText: 'Coach URL',
              helperText:
                  'Left as it is, this follows the Assistant server above and '
                  'adds /coach/auto.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _testing ? null : _test,
                icon: const Icon(Icons.send),
                label: Text(_testing ? 'Sending...' : 'Send a test line'),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
          if (_testResult.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_testResult, style: theme.textTheme.bodyMedium),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What it is doing now',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    _coach.isRunning
                        ? 'Listening through the phone microphone.'
                        : 'Not listening. The switch above is off, or it was '
                            'never switched on in this install.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Last thing heard: ${_coach.lastHeard.isEmpty ? 'nothing yet' : _coach.lastHeard}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    'Last line for the lens: ${_coach.lastLine.isEmpty ? 'none yet' : _coach.lastLine}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    'Where it went: ${_coach.lastOutcome}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use this to tell a blank lens apart from a silent coach: '
                    '"held back by the coach" is the feature working, '
                    '"lens write failed" means the glasses were not connected.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Battery: the microphone and the network stay awake, so expect '
            'hours rather than a day. Turn it on when the conversation starts.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
