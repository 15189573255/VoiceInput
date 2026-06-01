import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'speech_provider.dart';

/// SpeechProvider backed by the device's system STT via the speech_to_text
/// package. Works offline on devices with Google's on-device model installed,
/// otherwise falls back to network recognition.
class SystemSpeechProvider implements SpeechProvider {
  final stt.SpeechToText _engine = stt.SpeechToText();
  StreamController<SpeechEvent>? _ctrl;
  bool _initialized = false;
  String? _lastError;

  // Track the latest partial so we can fall back to it as the "final" result
  // if the engine reports done without ever delivering a true final.
  String _lastPartial = '';
  bool _finalEmitted = false;

  @override
  String? get lastError => _lastError;

  @override
  Future<bool> initialize() async {
    if (_initialized && _engine.isAvailable) return true;
    try {
      _initialized = await _engine.initialize(
        onError: (e) {
          _lastError = e.errorMsg;
          _ctrl?.add(SpeechEvent.error(e.errorMsg));
        },
        onStatus: (status) {
          // "done" / "doneNoResult" both signal the engine has fully stopped.
          // On MIUI mibrain the timing is: doneNoResult -> 200-1000ms ->
          // actual onResult callback. We emit done unconditionally so the UI
          // can leave the listening state; if a real final shows up later
          // it'll still flow through and overwrite the buffer.
          if (status == 'done' || status == 'doneNoResult') {
            final ctrl = _ctrl;
            if (ctrl == null) return;
            if (!_finalEmitted && _lastPartial.isNotEmpty) {
              ctrl.add(SpeechEvent.finalResult(_lastPartial));
              _finalEmitted = true;
            }
            ctrl.add(const SpeechEvent.done());
          }
        },
        debugLogging: true,
      );
      if (!_initialized) {
        _lastError ??=
            'SpeechRecognizer unavailable. Check that a system speech engine is installed and authorized.';
      } else {
        _lastError = null;
      }
    } catch (e) {
      _initialized = false;
      _lastError = e.toString();
    }
    return _initialized;
  }

  @override
  Stream<SpeechEvent> start({String locale = 'zh_CN'}) {
    _ctrl?.close();
    final ctrl = StreamController<SpeechEvent>.broadcast();
    _ctrl = ctrl;
    _lastPartial = '';
    _finalEmitted = false;
    // Fire-and-forget: ensure any prior session is fully released before
    // calling listen() again. MIUI's mibrain otherwise returns ERROR_CLIENT
    // (5) when a stale listener is still attached.
    _startListen(ctrl, locale);
    return ctrl.stream;
  }

  Future<void> _startListen(
      StreamController<SpeechEvent> ctrl, String locale) async {
    if (_engine.isListening) {
      await _engine.cancel();
      // Small breathing room for the system recogniser to release its bind.
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _engine.listen(
      listenOptions: stt.SpeechListenOptions(
        // Keep the recogniser open long enough for MIUI's mibrain to deliver
        // its final result after onEndOfSpeech. Default pauseFor (~3s) is too
        // short on this stack and causes silently-dropped results.
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        localeId: locale,
      ),
      onResult: (r) {
        if (r.finalResult) {
          _finalEmitted = true;
          ctrl.add(SpeechEvent.finalResult(r.recognizedWords));
        } else {
          _lastPartial = r.recognizedWords;
          ctrl.add(SpeechEvent.partial(r.recognizedWords));
        }
      },
    );
  }

  @override
  Future<void> stop() async {
    // MIUI's mibrain delivers its final ASR_DATA up to ~1 s AFTER our call to
    // onStopListening. We intentionally do NOT close _ctrl here — the late
    // final + the status:done event still need to flow through. The next
    // start() (or cancel/dispose) will close it.
    await _engine.stop();
  }

  @override
  Future<void> cancel() async {
    await _engine.cancel();
    await _ctrl?.close();
    _ctrl = null;
  }

  @override
  bool get isListening => _engine.isListening;
}
