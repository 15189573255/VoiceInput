import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ime/ime_bridge.dart';
import '../../core/protocol/messages.dart';
import '../../core/speech/speech_provider.dart';
import '../../core/speech/system_speech_provider.dart';
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
  final SpeechProvider _speech = SystemSpeechProvider();
  WsClient? _ws;
  TokenStore? _tokens;

  final _bufferCtrl = TextEditingController();

  StreamSubscription<SpeechEvent>? _speechSub;
  StreamSubscription<WsState>? _wsStateSub;
  StreamSubscription<ImeEvent>? _imeSub;

  _Dest _dest = _Dest.phone;
  bool _listening = false;
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
  }

  @override
  void dispose() {
    _speechSub?.cancel();
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
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      setState(() => _status = 'Microphone denied');
      return;
    }
    final ok = await _speech.initialize();
    if (!ok) {
      setState(() => _status = _speech.lastError ?? 'Speech engine unavailable');
      return;
    }
    setState(() {
      _listening = true;
      _status = 'Listening…';
    });
    _sessionPrefix = _bufferCtrl.text;
    _speechSub?.cancel();
    _speechSub = _speech.start().listen((ev) {
      switch (ev.kind) {
        case SpeechEventKind.partial:
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          setState(() => _status = 'Hearing… ${ev.text.length}c');
          break;
        case SpeechEventKind.finalResult:
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          _sessionPrefix = combined;
          setState(() {
            _listening = false;
            _status = 'Ready';
          });
          break;
        case SpeechEventKind.done:
          setState(() {
            _listening = false;
            if (_status == null || _status!.startsWith('Hearing')) {
              _status = _bufferCtrl.text.isEmpty ? 'No speech' : 'Ready';
            }
          });
          break;
        case SpeechEventKind.error:
          setState(() {
            _listening = false;
            _status = 'ASR error: ${ev.errorCode}';
          });
          break;
      }
    });
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
      _status = _dest == _Dest.phone ? 'Inserted' : 'Sent to PC';
    });
  }

  Future<void> _connectPc() async {
    final store = _tokens;
    if (store == null) return;
    final peer = store.lastPeer;
    if (peer == null) {
      setState(() => _status = 'Pair in VoiceInput app first');
      return;
    }
    setState(() => _status = 'Connecting…');
    try {
      await _ws!.connect(peer.host, peer.port);
    } catch (_) {
      setState(() => _status = 'Connect failed');
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
          _MicBar(listening: _listening, onTap: _toggleListen),
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
              label: const Text('Phone'),
              icon: const Icon(Icons.smartphone, size: 16),
            ),
            ButtonSegment(
              value: _Dest.pc,
              label: Text(wsConnected ? 'PC' : 'PC·'),
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
            status ?? (hostApp != null ? '→ $hostApp' : 'Tap mic to dictate'),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Switch keyboard',
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
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Buffer',
              ),
            ),
          ),
          IconButton(
            onPressed: controller.text.isEmpty ? null : onClear,
            icon: const Icon(Icons.backspace_outlined, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Clear buffer',
          ),
          FilledButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Send'),
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
  final VoidCallback onTap;
  const _MicBar({required this.listening, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
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
            Icon(listening ? Icons.stop_rounded : Icons.mic_rounded,
                color: listening ? cs.onPrimary : cs.onSurface, size: 22),
            const SizedBox(width: 8),
            Text(
              listening ? 'Tap to stop' : 'Tap to dictate',
              style: TextStyle(
                color: listening ? cs.onPrimary : cs.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
