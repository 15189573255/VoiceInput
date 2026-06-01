import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../protocol/messages.dart';
import 'token_store.dart';

/// Lifecycle of a connection to the desktop receiver.
///
/// connecting -> awaitingPin: server replied to hello with NeedPIN.
/// connecting -> authed     : server replied to hello with OK + token.
/// awaitingPin -> authed    : user typed correct PIN.
/// awaitingPin -> locked    : 3 wrong PIN attempts.
/// any -> disconnected      : socket dropped or stop() called.
enum WsState { disconnected, connecting, awaitingPin, authed, locked }

class PairingError {
  final String code;
  final String message;
  PairingError(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

class WsClient {
  final TokenStore tokens;
  final String deviceName;

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;

  final _stateCtrl = StreamController<WsState>.broadcast();
  final _msgCtrl = StreamController<Envelope>.broadcast();
  final _errorCtrl = StreamController<PairingError>.broadcast();

  WsState _state = WsState.disconnected;
  String? _currentHost;
  int? _currentPort;

  WsClient({required this.tokens, this.deviceName = 'Mobile'});

  WsState get state => _state;
  Stream<WsState> get states => _stateCtrl.stream;
  Stream<Envelope> get messages => _msgCtrl.stream;
  Stream<PairingError> get errors => _errorCtrl.stream;

  Future<void> connect(String host, int port) async {
    await disconnect();
    _setState(WsState.connecting);
    _currentHost = host;
    _currentPort = port;
    try {
      final uri = Uri.parse('ws://$host:$port/ws');
      _channel = IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 20));
      _sub = _channel!.stream.listen(
        _onRaw,
        onError: (_) => _onClosed(),
        onDone: _onClosed,
        cancelOnError: true,
      );
      // Fire the hello as soon as the socket is open. If we have a stored
      // token for this host, ride straight into Authed; otherwise the server
      // will respond with NeedPIN.
      final token = tokens.tokenFor(host, port);
      final hello = <String, dynamic>{
        'deviceId': tokens.deviceId,
        'deviceName': deviceName,
      };
      if (token != null) hello['token'] = token;
      _send(Envelope(type: MsgType.hello, data: hello));
    } catch (e) {
      _setState(WsState.disconnected);
      rethrow;
    }
  }

  /// Submits a PIN to finish the pairing handshake.
  void submitPin(String pin) {
    if (_state != WsState.awaitingPin) return;
    _send(Envelope(type: MsgType.pairPin, data: {'pin': pin}));
  }

  /// Sends a business payload (text/input, text/clear). No-ops unless authed.
  void send(Envelope env) {
    if (_state != WsState.authed) return;
    _send(env);
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    if (_channel != null) {
      await _channel!.sink.close(ws_status.normalClosure);
      _channel = null;
    }
    _currentHost = null;
    _currentPort = null;
    _setState(WsState.disconnected);
  }

  void _send(Envelope env) {
    if (_channel == null) return;
    _channel!.sink.add(env.encode());
  }

  void _onRaw(dynamic raw) {
    final Envelope env;
    try {
      env = Envelope.decode(raw as String);
    } catch (_) {
      return;
    }

    if (env.type == MsgType.pairResult) {
      final d = env.data ?? const {};
      final ok = d['ok'] == true;
      final needPin = d['needPin'] == true;
      final token = d['token'] as String?;
      final code = d['code'] as String?;
      if (ok) {
        if (_currentHost != null && _currentPort != null) {
          if (token != null && token.isNotEmpty) {
            tokens.save(_currentHost!, _currentPort!, token);
          }
          // Remember as last successful peer so the IME can auto-connect.
          tokens.setLastPeer(_currentHost!, _currentPort!);
        }
        _setState(WsState.authed);
      } else if (code == 'locked') {
        _setState(WsState.locked);
        _errorCtrl.add(PairingError('locked', 'Too many wrong PINs; device locked for 60 s.'));
      } else if (needPin) {
        _setState(WsState.awaitingPin);
        if (code == 'invalid_pin') {
          _errorCtrl.add(PairingError('invalid_pin', 'Wrong PIN, try again.'));
        } else if (code == 'bad_token') {
          // The stored token is no longer accepted (desktop forgot us).
          if (_currentHost != null && _currentPort != null) {
            tokens.forget(_currentHost!, _currentPort!);
          }
        }
      } else if (code != null) {
        _errorCtrl.add(PairingError(code, code));
      }
      return;
    }

    _msgCtrl.add(env);
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _currentHost = null;
    _currentPort = null;
    _setState(WsState.disconnected);
  }

  void _setState(WsState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }

  void dispose() {
    disconnect();
    _stateCtrl.close();
    _msgCtrl.close();
    _errorCtrl.close();
  }
}
