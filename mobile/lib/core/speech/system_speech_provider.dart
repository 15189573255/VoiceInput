import 'dart:async';

import 'package:flutter/foundation.dart';
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
  // Remember the locale of the current session so an in-session transient
  // retry (e.g. on error_network_timeout) can re-listen with the same locale
  // without needing a fresh start() call from the UI.
  String _currentLocale = 'zh_CN';
  // Whether we've already burned the single allowed transient retry for the
  // current session. Reset on every start(), so each user tap gets at most
  // one silent retry — never an infinite loop.
  bool _retriedTransient = false;

  @override
  String? get lastError => _lastError;

  @override
  Future<bool> initialize() async {
    if (_initialized && _engine.isAvailable) return true;
    try {
      _initialized = await _engine.initialize(
        onError: (e) {
          debugPrint('[SystemASR] error msg=${e.errorMsg} permanent=${e.permanent}');
          _lastError = e.errorMsg;
          // Some errors are transient — most notably error_network_timeout,
          // which Google's on-device shim emits after the recognizer has been
          // idle for a while (cold-start handshake with the speech service
          // takes longer than its 5 s budget). On the second attempt it
          // almost always succeeds, so we silently restart once per session
          // instead of surfacing a failure the user has to tap through.
          final ctrl = _ctrl;
          if (ctrl != null && !ctrl.isClosed &&
              !_retriedTransient && _isTransient(e.errorMsg)) {
            _retriedTransient = true;
            debugPrint('[SystemASR] transient "${e.errorMsg}", silent retry');
            Future.delayed(const Duration(milliseconds: 300), () {
              final c = _ctrl;
              if (c == null || c.isClosed) return;
              _startListen(c, _currentLocale);
            });
            return;
          }
          _ctrl?.add(SpeechEvent.error(e.errorMsg));
        },
        onStatus: (status) {
          debugPrint('[SystemASR] status=$status');
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
    _currentLocale = locale;
    _retriedTransient = false;
    // Fire-and-forget: ensure any prior session is fully released before
    // calling listen() again. MIUI's mibrain otherwise returns ERROR_CLIENT
    // (5) when a stale listener is still attached.
    _startListen(ctrl, locale);
    return ctrl.stream;
  }

  bool _isTransient(String msg) {
    // Google's online recognizer surfaces these whenever the handshake to the
    // speech service hasn't been kept warm; a single retry recovers the
    // session. error_busy can also show up if a prior cancel hasn't settled.
    return msg.contains('error_network_timeout') ||
        msg.contains('error_network') ||
        msg.contains('error_busy');
  }

  Future<void> _startListen(
      StreamController<SpeechEvent> ctrl, String locale) async {
    debugPrint('[SystemASR] startListen locale=$locale wasListening=${_engine.isListening}');
    if (_engine.isListening) {
      await _engine.cancel();
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _engine.listen(
      listenOptions: stt.SpeechListenOptions(
        // Allow up to 2 minutes of continuous dictation. The default 30 s
        // was clipping anyone who tried to dictate a longer thought; partials
        // keep coming the whole time so the safety watchdog upstream still
        // protects against stuck sessions.
        listenFor: const Duration(seconds: 120),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        localeId: locale,
      ),
      onResult: (r) {
        debugPrint('[SystemASR] onResult final=${r.finalResult} words="${r.recognizedWords}"');
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
