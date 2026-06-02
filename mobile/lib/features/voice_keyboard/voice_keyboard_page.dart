import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/i18n/i18n.dart';
import '../../core/polish/polish.dart';
import '../../core/polish/polish_settings.dart';
import '../../core/protocol/messages.dart';
import '../../core/snippets/snippet_store.dart';
import '../../core/speech/speech_provider.dart';
import '../../core/speech/speech_settings.dart';
import '../../core/transport/discovery.dart';
import '../../core/transport/token_store.dart';
import '../../core/transport/ws_client.dart';
import '../settings/settings_page.dart';
import 'chips_row.dart';

const _kPrefSuffix = 'pref_suffix';
const _kPrefPolish = 'pref_polish';
const _kPrefManualHost = 'pref_manual_host';
const _kPrefManualPort = 'pref_manual_port';

/// Mobile phase-2 page: auto-discover desktops via mDNS+UDP, fall back to a
/// manual host/port entry, run the PIN handshake on first connect, then drive
/// the voice → buffer → send loop.
class VoiceKeyboardPage extends StatefulWidget {
  const VoiceKeyboardPage({super.key});

  @override
  State<VoiceKeyboardPage> createState() => _VoiceKeyboardPageState();
}

class _VoiceKeyboardPageState extends State<VoiceKeyboardPage> {
  final Discovery _discovery = Discovery();
  final SnippetStore _snipStore = SnippetStore();
  final PolishSettingsStore _polishStore = PolishSettingsStore();
  final SpeechSettingsStore _speechStore = SpeechSettingsStore();
  WsClient? _ws;
  TokenStore? _tokens;
  SpeechProvider? _speech; // built from settings on demand

  final _manualHostCtrl = TextEditingController();
  final _manualPortCtrl = TextEditingController(text: '53118');
  final _bufferCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  StreamSubscription<SpeechEvent>? _speechSub;
  StreamSubscription<WsState>? _stateSub;
  StreamSubscription<PairingError>? _errSub;
  StreamSubscription<List<DiscoveredService>>? _discoverySub;
  StreamSubscription<Envelope>? _msgSub;
  StreamSubscription<SnippetSnapshot>? _snipSub;
  Timer? _safetyTimer;

  List<DiscoveredService> _devices = [];
  DiscoveredService? _activeDevice;
  WsState _wsState = WsState.disconnected;
  bool _listening = false;
  // Snapshot of the buffer at the moment the current ASR session started.
  // New partial/final text is appended to this prefix so consecutive
  // recordings accumulate instead of overwriting each other.
  String _sessionPrefix = '';
  String _suffix = 'none';
  PolishMode _polish = PolishMode.raw;
  bool _polishing = false;
  String? _statusLine;
  SnippetSnapshot _snipSnap = const SnippetSnapshot();
  int? _activeCategoryId;

  // Track when the user has tapped into the buffer to edit. While the OS
  // keyboard is up, we hide the chips + mic to give the buffer all the
  // remaining space (otherwise it collapses to one line).
  final FocusNode _bufferFocus = FocusNode();
  bool _bufferHasFocus = false;

  List<String> get _hotwords => _snipSnap.dictionary.map((e) => e.term).toList();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _tokens = await TokenStore.open();
    _ws = WsClient(tokens: _tokens!);

    final p = await SharedPreferences.getInstance();
    setState(() {
      _suffix = p.getString(_kPrefSuffix) ?? 'none';
      _polish = PolishModeX.fromWire(p.getString(_kPrefPolish));
      _manualHostCtrl.text = p.getString(_kPrefManualHost) ?? '';
      _manualPortCtrl.text = (p.getInt(_kPrefManualPort) ?? 53118).toString();
    });

    await _polishStore.load();
    // If the user hasn't picked a polish mode yet, default to the settings'
    // preferred mode (which is "Light" out of the box).
    if (p.getString(_kPrefPolish) == null) {
      setState(() => _polish = _polishStore.current.defaultMode);
    }

    await _speechStore.load();
    _speech = _speechStore.current.buildProvider(hotwords: _hotwords);
    // Rebuild the speech provider whenever settings change (engine swap, key
    // edit) so the next mic tap uses the new config without a restart.
    _speechStore.changes.listen((s) {
      _speech = s.buildProvider(hotwords: _hotwords);
    });

    // TextEditingController doesn't trigger parent rebuilds when its text
    // changes (from ASR or user edits). Without this listener the Send button
    // never updates its disabled state after the buffer fills up.
    _bufferCtrl.addListener(_onBufferChanged);
    _bufferFocus.addListener(() {
      if (_bufferFocus.hasFocus != _bufferHasFocus) {
        setState(() => _bufferHasFocus = _bufferFocus.hasFocus);
      }
    });

    _stateSub = _ws!.states.listen((s) {
      setState(() {
        _wsState = s;
        // Clear the "Connecting to X…" hint once we land in a terminal state,
        // otherwise it lingers on the buffer card and looks stuck.
        if (s == WsState.authed) _statusLine = null;
        if (s == WsState.disconnected && _statusLine != null &&
            _statusLine!.startsWith('Connecting')) {
          _statusLine = null;
        }
      });
    });
    _errSub = _ws!.errors.listen((e) {
      setState(() => _statusLine = e.message);
    });
    _discoverySub = _discovery.services.listen((list) {
      setState(() => _devices = list);
    });

    // Hydrate cached snippets immediately so chips appear even before the WS
    // is up; the desktop will push a fresh snapshot on auth.
    await _snipStore.load();
    _applySnapshot(_snipStore.current);
    _snipSub = _snipStore.changes.listen(_applySnapshot);
    _msgSub = _ws!.messages.listen(_onServerMessage);

    await _discovery.start();
  }

  void _applySnapshot(SnippetSnapshot snap) {
    setState(() {
      _snipSnap = snap;
      if (_activeCategoryId == null && snap.categories.isNotEmpty) {
        _activeCategoryId = snap.categories.first.id;
      } else if (_activeCategoryId != null &&
          snap.categories.every((c) => c.id != _activeCategoryId)) {
        _activeCategoryId = snap.categories.isNotEmpty ? snap.categories.first.id : null;
      }
    });
  }

  void _onServerMessage(Envelope env) {
    switch (env.type) {
      case MsgType.snippetsSnapshot:
        if (env.data == null) return;
        final snap = SnippetSnapshot.fromJson(env.data!);
        _snipStore.apply(snap); // persists + emits via changes stream
        break;
      case MsgType.focusUpdate:
        final d = env.data ?? const <String, dynamic>{};
        final suggested = d['suggestedCategory'] as String?;
        if (suggested != null && suggested.isNotEmpty) {
          final match = _snipSnap.categories.where((c) => c.name == suggested);
          if (match.isNotEmpty) {
            setState(() => _activeCategoryId = match.first.id);
          }
        }
        break;
    }
  }

  void _pickSnippet(String content) {
    final cursor = _bufferCtrl.selection.baseOffset;
    final current = _bufferCtrl.text;
    if (cursor < 0 || cursor > current.length) {
      _bufferCtrl.text = current + content;
    } else {
      _bufferCtrl.text = current.substring(0, cursor) + content + current.substring(cursor);
    }
    final newPos = (cursor < 0 ? _bufferCtrl.text.length : cursor + content.length);
    _bufferCtrl.selection = TextSelection.collapsed(offset: newPos);
  }

  void _onBufferChanged() {
    // Only rebuild — the value lives in the controller itself.
    setState(() {});
  }

  @override
  void dispose() {
    _safetyTimer?.cancel();
    _bufferCtrl.removeListener(_onBufferChanged);
    _bufferFocus.dispose();
    _speechSub?.cancel();
    _stateSub?.cancel();
    _errSub?.cancel();
    _discoverySub?.cancel();
    _msgSub?.cancel();
    _snipSub?.cancel();
    _snipStore.dispose();
    _polishStore.dispose();
    _speechStore.dispose();
    _ws?.dispose();
    _discovery.dispose();
    _manualHostCtrl.dispose();
    _manualPortCtrl.dispose();
    _bufferCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _connectTo(DiscoveredService svc) async {
    setState(() {
      _activeDevice = svc;
      _statusLine = 'Connecting to ${svc.name}…';
    });
    try {
      await _ws!.connect(svc.host, svc.port);
    } catch (e) {
      setState(() => _statusLine = 'Connect failed: $e');
    }
  }

  Future<void> _connectManual() async {
    final host = _manualHostCtrl.text.trim();
    final port = int.tryParse(_manualPortCtrl.text.trim()) ?? 0;
    if (host.isEmpty || port == 0) {
      setState(() => _statusLine = 'Enter host and port');
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefManualHost, host);
    await p.setInt(_kPrefManualPort, port);
    _discovery.addManual(host, port);
    await _connectTo(DiscoveredService(
      name: host,
      host: host,
      port: port,
      source: DiscoverySource.manual,
    ));
  }

  Future<void> _disconnect() async {
    await _ws?.disconnect();
    setState(() {
      _activeDevice = null;
      _statusLine = 'Disconnected';
    });
  }

  void _submitPin() {
    final pin = _pinCtrl.text.trim();
    if (pin.length != 6) {
      setState(() => _statusLine = 'PIN must be 6 digits');
      return;
    }
    _ws?.submitPin(pin);
    _pinCtrl.clear();
  }

  Future<void> _startListening() async {
    if (_listening) return;
    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      setState(() => _statusLine = tr('mic.errPermission'));
      return;
    }
    // Rebuild on each tap so the latest dictionary always flows in as hotwords.
    final speech = _speech = _speechStore.current.buildProvider(hotwords: _hotwords);
    final ok = await speech.initialize();
    if (!ok) {
      final err = speech.lastError ?? tr('mic.errEngine');
      setState(() => _statusLine = err);
      return;
    }
    setState(() {
      _listening = true;
      _statusLine = tr('dash.listening');
    });
    // Capture whatever is already in the buffer so the new utterance appends
    // to it rather than replacing prior recordings.
    _sessionPrefix = _bufferCtrl.text;
    debugPrint('[ASR] start engine=${_speechStore.current.engine} prefixLen=${_sessionPrefix.length}');
    _speechSub?.cancel();
    _armSafetyTimer();
    _speechSub = speech.start().listen((ev) {
      debugPrint('[ASR] event ${ev.kind} textLen=${ev.text.length} err=${ev.errorCode}');
      switch (ev.kind) {
        case SpeechEventKind.partial:
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          // Each partial proves the engine is still alive; reset the safety
          // window so a continuous monologue isn't cut short at 25 s.
          _armSafetyTimer();
          setState(() => _statusLine = tr('mic.hearing', [ev.text.length]));
          break;
        case SpeechEventKind.finalResult:
          _safetyTimer?.cancel();
          final combined = _joinSegment(_sessionPrefix, ev.text);
          _bufferCtrl.text = combined;
          _bufferCtrl.selection = TextSelection.collapsed(offset: combined.length);
          // Promote final to the new prefix so any late partial from a stale
          // session can't roll the buffer back to before this final.
          _sessionPrefix = combined;
          setState(() {
            _listening = false;
            _statusLine = tr('buf.statusReadyToSend');
          });
          break;
        case SpeechEventKind.done:
          _safetyTimer?.cancel();
          setState(() {
            _listening = false;
            if (_statusLine == null ||
                _statusLine!.startsWith(tr('mic.hearing', [0]).split('…').first)) {
              _statusLine = _bufferCtrl.text.isEmpty
                  ? tr('mic.noSpeech')
                  : tr('buf.statusReadyToSend');
            }
          });
          break;
        case SpeechEventKind.error:
          _safetyTimer?.cancel();
          setState(() {
            _listening = false;
            _statusLine = 'ASR: ${ev.errorCode}';
          });
          break;
      }
    }, onDone: () {
      debugPrint('[ASR] stream done');
      setState(() => _listening = false);
    });
  }

  // Append a new ASR segment to the buffer prefix. Inserts a single ASCII
  // space when the boundary would otherwise glue two words together; skips
  // the space if the prefix already ends with whitespace/punctuation or if
  // either side of the boundary is CJK (which natively reads without spaces).
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
    // ASCII whitespace + common punctuation (latin + fullwidth/CJK).
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return true;
    const punct = {
      0x2C, 0x2E, 0x21, 0x3F, 0x3B, 0x3A, // , . ! ? ; :
      0x3001, 0x3002, 0xFF0C, 0xFF1F, 0xFF01, 0xFF1B, 0xFF1A, // 、。，？！；：
      0x2026, 0x2014, // … —
    };
    return punct.contains(c);
  }

  bool _isCjk(int c) {
    return (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x3040 && c <= 0x30FF) ||
        (c >= 0xAC00 && c <= 0xD7AF);
  }

  void _armSafetyTimer() {
    _safetyTimer?.cancel();
    // Restart the watchdog. The window is generous (40 s of pure silence)
    // because partials should keep restarting it during real speech; if no
    // partial / final / done arrives in this window the engine is genuinely
    // stuck and we bail out so the UI isn't stranded on "listening…".
    _safetyTimer = Timer(const Duration(seconds: 40), () {
      if (!_listening) return;
      debugPrint('[ASR] safety timeout — forcing stop');
      _speech?.stop();
      setState(() {
        _listening = false;
        _statusLine = tr('mic.noSpeech');
      });
    });
  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    await _speech?.stop();
    setState(() => _listening = false);
  }

  Future<void> _setSuffix(String v) async {
    setState(() => _suffix = v);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefSuffix, v);
  }

  Future<void> _setPolish(PolishMode v) async {
    setState(() => _polish = v);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPrefPolish, v.wire);
  }

  /// Run the configured polish provider on the current buffer in place. Lets
  /// the user inspect/edit the polished text before sending — matches the
  /// "two-level buffer" idea: ASR fills, polish refines, user reviews, sends.
  Future<void> _runPolish() async {
    final raw = _bufferCtrl.text.trim();
    if (raw.isEmpty || _polishing) return;
    final provider = _polishStore.current.buildProvider();
    if (provider == null) {
      setState(() => _statusLine = 'Configure provider in Settings');
      return;
    }
    setState(() {
      _polishing = true;
      _statusLine = 'Polishing…';
    });
    try {
      final hotwords = _snipSnap.dictionary.map((e) => e.term).toList();
      final res = await provider.polish(PolishRequest(
        mode: _polish == PolishMode.raw ? PolishMode.light : _polish,
        text: raw,
        locale: 'zh',
        hotwords: hotwords,
      ));
      _bufferCtrl.text = res.text;
      _bufferCtrl.selection = TextSelection.collapsed(offset: res.text.length);
      setState(() => _statusLine = 'Polished · ${res.provider}');
    } catch (e) {
      setState(() => _statusLine = e.toString());
    } finally {
      setState(() => _polishing = false);
    }
  }

  void _sendBuffer() {
    final text = _bufferCtrl.text;
    if (text.isEmpty || _wsState != WsState.authed) return;
    _ws?.send(Envelope(type: MsgType.textInput, data: {
      'text': text,
      'suffix': _suffix == 'none' ? '' : _suffix,
      'mode': 'auto',
      // polish already happened locally; desktop just injects.
    }));
    setState(() {
      _bufferCtrl.clear();
      _statusLine = 'Sent';
    });
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(polishStore: _polishStore, speechStore: _speechStore),
    ));
  }

  void _sendClear() {
    if (_wsState != WsState.authed) return;
    _ws?.send(Envelope(type: MsgType.textClear));
    setState(() => _statusLine = 'Clear sent');
  }

  Color _stateColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (_wsState) {
      case WsState.authed:
        return cs.primary;
      case WsState.connecting:
      case WsState.awaitingPin:
        return cs.tertiary;
      case WsState.locked:
        return cs.error;
      case WsState.disconnected:
        return cs.outline;
    }
  }

  String _stateLabel() {
    switch (_wsState) {
      case WsState.authed:
        return tr('state.paired', [_activeDevice?.name ?? tr('common.connect')]);
      case WsState.connecting:
        return tr('state.connecting');
      case WsState.awaitingPin:
        return tr('state.awaitingPin');
      case WsState.locked:
        return tr('state.locked');
      case WsState.disconnected:
        return _activeDevice == null ? tr('state.chooseDevice') : tr('state.disconnected');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(tr('app.title')),
        centerTitle: false,
        backgroundColor: cs.surface,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('common.rescan'),
            onPressed: () async {
              await _discovery.stop();
              await _discovery.start();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: tr('common.settings'),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Show the standalone status bar only in pre-auth states.
              // When authed, _DisconnectBar carries the same info plus the
              // disconnect action, so the duplicate bar at top would just
              // crowd the layout.
              if (_wsState != WsState.authed) ...[
                _StateBar(label: _stateLabel(), color: _stateColor(context)),
                const SizedBox(height: 10),
              ],
              if (_wsState == WsState.awaitingPin)
                Expanded(
                  child: _PinEntry(
                    controller: _pinCtrl,
                    onSubmit: _submitPin,
                    onCancel: _disconnect,
                  ),
                )
              else if (_wsState == WsState.disconnected || _wsState == WsState.connecting)
                Expanded(
                  child: _DevicePicker(
                    devices: _devices,
                    manualHost: _manualHostCtrl,
                    manualPort: _manualPortCtrl,
                    connecting: _wsState == WsState.connecting,
                    onConnectDiscovered: _connectTo,
                    onConnectManual: _connectManual,
                  ),
                )
              else ...[
                _DisconnectBar(label: _stateLabel(), onDisconnect: _disconnect),
                const SizedBox(height: 10),
                // Hide chips while the user is editing the buffer with the
                // system keyboard — otherwise the buffer's visible area
                // shrinks to a single line.
                if (_snipSnap.categories.isNotEmpty && !_bufferHasFocus)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ChipsRow(
                      snapshot: _snipSnap,
                      activeCategoryId: _activeCategoryId,
                      onSelectCategory: (id) => setState(() => _activeCategoryId = id),
                      onPickSnippet: _pickSnippet,
                    ),
                  ),
                Expanded(
                  child: _BufferCard(
                    controller: _bufferCtrl,
                    focusNode: _bufferFocus,
                    statusLine: _statusLine,
                    suffix: _suffix,
                    polish: _polish,
                    polishing: _polishing,
                    polishConfigured: _polishStore.current.isConfigured,
                    onSuffixChanged: _setSuffix,
                    onPolishChanged: _setPolish,
                    onPolish: _runPolish,
                    onSend: _sendBuffer,
                    onClear: () => _bufferCtrl.clear(),
                    onSendClear: _sendClear,
                    canSend: _wsState == WsState.authed && _bufferCtrl.text.isNotEmpty,
                  ),
                ),
                // Mic stays visible even when the buffer has focus so the
                // user can always switch back to voice. The button shrinks
                // in edit mode to free vertical space for typing.
                const SizedBox(height: 10),
                _MicButton(
                  listening: _listening,
                  compact: _bufferHasFocus,
                  onPressed: () {
                    if (_bufferHasFocus) {
                      // Tapping the mic from edit mode means "I want to talk
                      // again" → drop focus / keyboard, then start listening.
                      _bufferFocus.unfocus();
                    }
                    _listening ? _stopListening() : _startListening();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StateBar extends StatelessWidget {
  final String label;
  final Color color;
  const _StateBar({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
      ],
    );
  }
}

class _DevicePicker extends StatefulWidget {
  final List<DiscoveredService> devices;
  final TextEditingController manualHost;
  final TextEditingController manualPort;
  final bool connecting;
  final ValueChanged<DiscoveredService> onConnectDiscovered;
  final VoidCallback onConnectManual;

  const _DevicePicker({
    required this.devices,
    required this.manualHost,
    required this.manualPort,
    required this.connecting,
    required this.onConnectDiscovered,
    required this.onConnectManual,
  });

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  bool _showManual = false;
  Timer? _autoExpand;

  @override
  void initState() {
    super.initState();
    // After 5 s with no discovery hit, auto-expand the manual section so the
    // user has a path forward without hunting for a button.
    _autoExpand = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.devices.isEmpty && !_showManual) {
        setState(() => _showManual = true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _DevicePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If a device shows up, collapse manual back to keep the UI uncluttered
    // (unless the user already expanded it).
    if (oldWidget.devices.isEmpty && widget.devices.isNotEmpty) {
      _autoExpand?.cancel();
    }
  }

  @override
  void dispose() {
    _autoExpand?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(tr('pick.discovered'), style: Theme.of(context).textTheme.labelLarge),
                ),
                if (widget.connecting)
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (widget.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(tr('pick.scanning'),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              )
            else
              ...widget.devices.map((d) => _DeviceTile(svc: d, onTap: () => widget.onConnectDiscovered(d))),
            const Divider(height: 22),
            InkWell(
              onTap: () => setState(() => _showManual = !_showManual),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Text(tr('pick.manual'), style: Theme.of(context).textTheme.labelLarge),
                    const Spacer(),
                    Icon(_showManual ? Icons.expand_less : Icons.expand_more,
                        color: cs.onSurfaceVariant, size: 20),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: _showManual
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: widget.manualHost,
                              decoration: InputDecoration(
                                  isDense: true, labelText: tr('pick.host'), hintText: '192.168.x.x'),
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: widget.manualPort,
                              decoration: InputDecoration(isDense: true, labelText: tr('pick.port')),
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                              onPressed: widget.onConnectManual, child: Text(tr('pick.go'))),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DiscoveredService svc;
  final VoidCallback onTap;
  const _DeviceTile({required this.svc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tag = switch (svc.source) {
      DiscoverySource.mdns => 'mDNS',
      DiscoverySource.udp => 'UDP',
      DiscoverySource.manual => 'Manual',
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(Icons.computer_rounded, color: cs.onSurfaceVariant, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(svc.name, style: Theme.of(context).textTheme.bodyMedium),
                  Text('${svc.host}:${svc.port}',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.outlineVariant),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(tag, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinEntry extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;
  const _PinEntry({required this.controller, required this.onSubmit, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('pin.title'),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: const TextStyle(fontSize: 24, letterSpacing: 8, fontFeatures: [FontFeature.tabularFigures()]),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(onPressed: onCancel, child: Text(tr('common.cancel'))),
              const Spacer(),
              FilledButton(onPressed: onSubmit, child: Text(tr('pin.pair'))),
            ],
          ),
        ],
      ),
    );
  }
}

class _DisconnectBar extends StatelessWidget {
  final String label;
  final VoidCallback onDisconnect;
  const _DisconnectBar({required this.label, required this.onDisconnect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          TextButton(onPressed: onDisconnect, child: Text(tr('common.disconnect'))),
        ],
      ),
    );
  }
}

class _BufferCard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? statusLine;
  final String suffix;
  final PolishMode polish;
  final bool polishing;
  final bool polishConfigured;
  final ValueChanged<String> onSuffixChanged;
  final ValueChanged<PolishMode> onPolishChanged;
  final VoidCallback onPolish;
  final VoidCallback onSend;
  final VoidCallback onClear;
  final VoidCallback onSendClear;
  final bool canSend;

  const _BufferCard({
    required this.controller,
    required this.focusNode,
    required this.statusLine,
    required this.suffix,
    required this.polish,
    required this.polishing,
    required this.polishConfigured,
    required this.onSuffixChanged,
    required this.onPolishChanged,
    required this.onPolish,
    required this.onSend,
    required this.onClear,
    required this.onSendClear,
    required this.canSend,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Buffer', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (statusLine != null)
                Text(statusLine!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: tr('buf.hint'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Always show the full toolbar — dropdowns use PopupMenuButton
          // (rather than DropdownButton) so they cooperate cleanly with the
          // TextField's focus / keyboard state.
          Row(
            children: [
              _PolishMenu(value: polish, onChanged: onPolishChanged),
              const Spacer(),
              _SuffixMenu(value: suffix, onChanged: onSuffixChanged),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.backspace_outlined),
                tooltip: tr('buf.clearBuf'),
              ),
              IconButton(
                onPressed: onSendClear,
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: tr('buf.clearRemote'),
              ),
              const Spacer(),
              OutlinedButton.icon(
                icon: polishing
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high_outlined, size: 16),
                label: Text(polish == PolishMode.raw ? tr('buf.polish') : tr('polish.${polish.wire}')),
                onPressed: (polishing || !polishConfigured || controller.text.trim().isEmpty)
                    ? null
                    : onPolish,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: canSend ? onSend : null,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(tr('buf.send')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  final bool listening;
  final bool compact;
  final VoidCallback onPressed;
  const _MicButton({required this.listening, required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: compact ? 44 : 88,
        decoration: BoxDecoration(
          color: listening ? cs.primary : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(compact ? 12 : 20),
          border: Border.all(color: cs.outlineVariant),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(listening ? Icons.stop_rounded : Icons.mic_rounded,
                color: listening ? cs.onPrimary : cs.onSurface,
                size: compact ? 20 : 28),
            const SizedBox(width: 10),
            Text(
              listening ? tr('mic.tapToStop') : tr('mic.tapToDictate'),
              style: TextStyle(
                color: listening ? cs.onPrimary : cs.onSurface,
                fontSize: compact ? 13 : 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PopupMenuButton-backed picker for the polish mode. We use this instead of
/// DropdownButton so the menu opens cleanly while the buffer's OS keyboard is
/// up: PopupMenuButton uses a `showMenu` route rather than fighting for the
/// same focus the TextField currently owns.
class _PolishMenu extends StatelessWidget {
  final PolishMode value;
  final ValueChanged<PolishMode> onChanged;
  const _PolishMenu({required this.value, required this.onChanged});

  String _label(PolishMode m) {
    switch (m) {
      case PolishMode.raw:        return tr('polish.raw');
      case PolishMode.light:      return tr('polish.light');
      case PolishMode.structured: return tr('polish.structured');
      case PolishMode.formal:     return tr('polish.formal');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<PolishMode>(
      initialValue: value,
      tooltip: '',
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in PolishMode.values)
          PopupMenuItem(value: m, height: 38, child: Text(_label(m))),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_fix_high_outlined, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(_label(value), style: TextStyle(fontSize: 13, color: cs.onSurface)),
          Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _SuffixMenu extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SuffixMenu({required this.value, required this.onChanged});

  static const _items = [
    ['none',        ''],
    ['enter',       'Enter'],
    ['tab',         'Tab'],
    ['space',       'Space'],
    ['ctrl+enter',  'Ctrl+Enter'],
    ['alt+enter',   'Alt+Enter'],
    ['shift+enter', 'Shift+Enter'],
  ];

  String _label(String v) {
    if (v == 'none') return tr('suf.none');
    for (final pair in _items) {
      if (pair[0] == v) return pair[1];
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      initialValue: value,
      tooltip: '',
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final pair in _items)
          PopupMenuItem(value: pair[0], height: 38,
              child: Text(pair[0] == 'none' ? tr('suf.none') : pair[1])),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.keyboard_return, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(_label(value), style: TextStyle(fontSize: 13, color: cs.onSurface)),
          Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}
