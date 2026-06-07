import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/i18n/i18n.dart';
import '../../core/ime/ime_bridge.dart';
import '../../core/protocol/messages.dart';
import '../../core/speech/speech_provider.dart';
import '../../core/speech/speech_settings.dart';
import '../../core/transport/token_store.dart';
import '../../core/transport/ws_client.dart';

/// IME view: the panel shown to the user when VoiceInput is the active
/// keyboard. Compact, no Scaffold/AppBar — lives inside the system input
/// panel area.
///
/// Two destinations:
///   Phone mode: identified text is committed via [ImeBridge.commitText] to
///     whichever app launched the keyboard.
///   PC mode:    identified text is sent to the paired desktop receiver
///     over WebSocket, using the stored Token for auto-auth.
class ImeKeyboardView extends StatefulWidget {
  const ImeKeyboardView({super.key});

  @override
  State<ImeKeyboardView> createState() => _ImeKeyboardViewState();
}

enum _Dest { phone, pc }

class _ImeKeyboardViewState extends State<ImeKeyboardView> {
  final ImeBridge _ime = ImeBridge();
  final SpeechSettingsStore _speechStore = SpeechSettingsStore();
  // Built from the user's saved settings (same SharedPreferences blob the main
  // app writes), so picking "Volcengine streaming" in Settings gives the IME
  // real-time partial results too. Rebuilt on every mic tap and on changes.
  SpeechProvider? _speech;
  WsClient? _ws;
  TokenStore? _tokens;

  final _bufferCtrl = TextEditingController();

  StreamSubscription<SpeechEvent>? _speechSub;
  StreamSubscription<WsState>? _wsStateSub;
  StreamSubscription<ImeEvent>? _imeSub;

  _Dest _dest = _Dest.phone;
  bool _listening = false;
  // Mic trigger style, mirrored from the shared speech settings (tap vs hold).
  MicTriggerMode _micMode = MicTriggerMode.tap;
  // True while held in hold mode — guards the async-start race (see main page).
  bool _micHeld = false;
  // Buffer contents at the moment the current ASR session started; the new
  // utterance is appended to this so successive recordings accumulate.
  String _sessionPrefix = '';
  String? _status;
  WsState _wsState = WsState.disconnected;
  String? _hostApp;

  @override
  void initState() {
    super.initState();
    debugPrint('[ImeView] initState');
    _init();
  }

  Future<void> _init() async {
    debugPrint('[ImeView] _init begin');
    _tokens = await TokenStore.open();
    debugPrint('[ImeView] token store opened');
    _ws = WsClient(tokens: _tokens!, deviceName: 'MobileIME');
    _wsStateSub = _ws!.states.listen((s) {
      debugPrint('[ImeView] ws state -> $s');
      setState(() => _wsState = s);
    });

    _imeSub = _ime.events.listen((e) {
      if (e.kind == ImeEventKind.start) {
        setState(() => _hostApp = e.packageName);
      } else {
        setState(() => _hostApp = null);
      }
    });

    _bufferCtrl.addListener(() => setState(() {}));

    // Load the shared speech settings and build the configured engine. The main
    // app and the IME read the same blob, so whatever engine the user picked
    // (e.g. Volcengine streaming) applies to the IME as well.
    await _speechStore.load();
    _speech = _speechStore.current.buildProvider();
    if (mounted) setState(() => _micMode = _speechStore.current.micMode);
    _speechStore.changes.listen((s) {
      _speech = s.buildProvider();
      if (mounted) setState(() => _micMode = s.micMode);
    });
  }

  @override
  void dispose() {
    _speechSub?.cancel();
    _speech?.cancel();
    _speechStore.dispose();
    _wsStateSub?.cancel();
    _imeSub?.cancel();
    _ws?.dispose();
    _bufferCtrl.dispose();
    super.dispose();
  }

  bool get _canSend => _bufferCtrl.text.isNotEmpty &&
      (_dest == _Dest.phone || _wsState == WsState.authed);

  Future<void> _toggleListen() async {
    debugPrint('[ImeView] mic tap (currently listening=$_listening)');
    if (_listening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    await _speech?.stop();
    setState(() => _listening = false);
  }

  /// Hard-stop a recording on Send: drop the subscription + provider so a late
  /// final can't refill the buffer we just cleared, and reset the prefix.
  void _abortListening() {
    _speechSub?.cancel();
    _speechSub = null;
    _speech?.cancel();
    _sessionPrefix = '';
    if (_listening) setState(() => _listening = false);
  }

  Future<void> _startListening() async {
    if (_listening) return;
    // An IME has no host Activity, so we cannot REQUEST a runtime permission
    // here — permission_handler throws "Unable to detect current Android
    // Activity" and the whole tap is aborted (that's why the mic never started
    // even though the tap was received). Only CHECK the status; the user grants
    // RECORD_AUDIO once inside the main VoiceInput app, which is an Activity and
    // can show the system dialog. The grant is app-wide, so the IME inherits it.
    bool granted = false;
    try {
      granted = await Permission.microphone.isGranted;
    } catch (_) {
      granted = false;
    }
    if (!granted) {
      setState(() => _status = tr('ime.micGrantHint'));
      return;
    }
    // Rebuild from the latest settings on each tap so an engine/key change in
    // the main app takes effect here without restarting the keyboard.
    await _speech?.cancel();
    final speech = _speech = _speechStore.current.buildProvider();
    final ok = await speech.initialize();
    if (!ok) {
      setState(() => _status = speech.lastError ?? tr('mic.errEngine'));
      return;
    }
    setState(() {
      _listening = true;
      _status = tr('ime.listening');
    });
    _sessionPrefix = _bufferCtrl.text;
    _speechSub?.cancel();
    _speechSub = speech.start().listen((ev) {
      switch (ev.kind) {
        case SpeechEventKind.partial:
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          setState(() => _status = tr('mic.hearing', [ev.text.length]));
          break;
        case SpeechEventKind.finalResult:
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          _sessionPrefix = combined;
          setState(() {
            _listening = false;
            _status = tr('buf.statusReadyToSend');
          });
          break;
        case SpeechEventKind.done:
          setState(() {
            _listening = false;
            // Match the localized "hearing" prefix (zh「识别中」/ en "Hearing")
            // so a done arriving mid-recognition still resolves to a final
            // status instead of being stuck on the partial counter.
            final hearingPrefix = tr('mic.hearing', [0]).split('…').first;
            if (_status == null || _status!.startsWith(hearingPrefix)) {
              _status = _bufferCtrl.text.isEmpty
                  ? tr('mic.noSpeech')
                  : tr('buf.statusReadyToSend');
            }
          });
          break;
        case SpeechEventKind.error:
          setState(() {
            _listening = false;
            _status = tr('ime.asrError', [ev.errorCode ?? '']);
          });
          break;
      }
    });
    // Hold mode: finger already lifted while arming → stop immediately.
    if (_micMode == MicTriggerMode.hold && !_micHeld) {
      _stopListening();
    }
  }

  // See [VoiceKeyboardPage._joinSegment] — keeps consecutive ASR sessions
  // glued together with a sensible separator (or none, for CJK).
  String _joinSegment(String prefix, String segment) {
    if (prefix.isEmpty) return segment;
    if (segment.isEmpty) return prefix;
    final lastCode = prefix.codeUnitAt(prefix.length - 1);
    if (_isBoundaryChar(lastCode)) return prefix + segment;
    final firstCode = segment.codeUnitAt(0);
    if (_isCjk(lastCode) || _isCjk(firstCode)) return prefix + segment;
    return '$prefix $segment';
  }

  bool _isBoundaryChar(int c) {
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return true;
    const punct = {
      0x2C, 0x2E, 0x21, 0x3F, 0x3B, 0x3A,
      0x3001, 0x3002, 0xFF0C, 0xFF1F, 0xFF01, 0xFF1B, 0xFF1A,
      0x2026, 0x2014,
    };
    return punct.contains(c);
  }

  bool _isCjk(int c) {
    return (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0xAC00 && c <= 0xD7AF);
  }

  Future<void> _send() async {
    final text = _bufferCtrl.text;
    debugPrint('[ImeView] send dest=$_dest len=${text.length}');
    if (text.isEmpty) return;
    // Stop any live recording so the mic doesn't keep running after dispatch.
    _abortListening();
    if (_dest == _Dest.phone) {
      await _ime.commitText(text);
    } else {
      _ws?.send(Envelope(type: MsgType.textInput, data: {
        'text': text,
        'mode': 'auto',
      }));
    }
    setState(() {
      _bufferCtrl.clear();
      _status = _dest == _Dest.phone ? tr('ime.inserted') : tr('ime.sentToPc');
    });
  }

  Future<void> _connectPc() async {
    final store = _tokens;
    if (store == null) return;
    final peer = store.lastPeer;
    if (peer == null) {
      setState(() => _status = tr('ime.pairFirst'));
      return;
    }
    setState(() => _status = tr('state.connecting'));
    try {
      await _ws!.connect(peer.host, peer.port);
    } catch (_) {
      setState(() => _status = tr('ime.connectFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            dest: _dest,
            status: _status,
            hostApp: _hostApp,
            wsConnected: _wsState == WsState.authed,
            onDestChanged: (d) {
              setState(() => _dest = d);
              if (d == _Dest.pc && _wsState != WsState.authed) _connectPc();
            },
            onSwitchKeyboard: () => _ime.showImePicker(),
          ),
          const SizedBox(height: 6),
          _BufferRow(
            controller: _bufferCtrl,
            onClear: () => _bufferCtrl.clear(),
            onSend: _canSend ? _send : null,
          ),
          const SizedBox(height: 6),
          _MicBar(
            listening: _listening,
            holdMode: _micMode == MicTriggerMode.hold,
            onTap: _toggleListen,
            onHoldStart: () { _micHeld = true; if (!_listening) _startListening(); },
            onHoldEnd: () { _micHeld = false; if (_listening) _stopListening(); },
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final _Dest dest;
  final String? status;
  final String? hostApp;
  final bool wsConnected;
  final ValueChanged<_Dest> onDestChanged;
  final VoidCallback onSwitchKeyboard;

  const _TopBar({
    required this.dest,
    required this.status,
    required this.hostApp,
    required this.wsConnected,
    required this.onDestChanged,
    required this.onSwitchKeyboard,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        SegmentedButton<_Dest>(
          segments: [
            ButtonSegment(
              value: _Dest.phone,
              label: Text(tr('ime.destPhone')),
              icon: const Icon(Icons.smartphone, size: 16),
            ),
            ButtonSegment(
              value: _Dest.pc,
              label: Text(wsConnected ? tr('ime.destPc') : '${tr('ime.destPc')}·'),
              icon: const Icon(Icons.desktop_windows_outlined, size: 16),
            ),
          ],
          selected: {dest},
          onSelectionChanged: (s) => onDestChanged(s.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            status ?? (hostApp != null ? '→ $hostApp' : tr('mic.tapToDictate')),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: tr('ime.switchKeyboard'),
          icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
          onPressed: onSwitchKeyboard,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }
}

class _BufferRow extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onClear;
  final VoidCallback? onSend;

  const _BufferRow({required this.controller, required this.onClear, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              maxLines: 3,
              minLines: 1,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: tr('ime.bufferHint'),
              ),
            ),
          ),
          IconButton(
            onPressed: controller.text.isEmpty ? null : onClear,
            icon: const Icon(Icons.backspace_outlined, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: tr('buf.clearBuf'),
          ),
          FilledButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded, size: 16),
            label: Text(tr('buf.send')),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }
}

class _MicBar extends StatelessWidget {
  final bool listening;
  final bool holdMode;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  const _MicBar({
    required this.listening,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    this.holdMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = holdMode
        ? (listening ? tr('mic.holdToStop') : tr('mic.holdToDictate'))
        : (listening ? tr('mic.tapToStop') : tr('mic.tapToDictate'));
    final icon = (listening && !holdMode) ? Icons.stop_rounded : Icons.mic_rounded;
    final container = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 56,
      decoration: BoxDecoration(
        color: listening ? cs.primary : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: listening ? cs.onPrimary : cs.onSurface, size: 22),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: listening ? cs.onPrimary : cs.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    if (holdMode) {
      // Press-and-hold to record, release to stop — no long-press delay.
      return Listener(
        onPointerDown: (_) => onHoldStart(),
        onPointerUp: (_) => onHoldEnd(),
        onPointerCancel: (_) => onHoldEnd(),
        child: container,
      );
    }
    return GestureDetector(onTap: onTap, child: container);
  }
}
