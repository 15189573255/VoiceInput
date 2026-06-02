import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../protocol/messages.dart';
import 'token_store.dart';

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

  // Auto-reconnect state. Once a session reaches `authed`, we treat the next
  // unexpected close as a transient blip and retry with backoff. Surrendering
  // here is preferable to silently disconnecting the user mid-dictation.
  bool _wasAuthed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  static const _maxReconnects = 3;

  WsClient({required this.tokens, this.deviceName = 'Mobile'});

  WsState get state => _state;
  Stream<WsState> get states => _stateCtrl.stream;
  Stream<Envelope> get messages => _msgCtrl.stream;
  Stream<PairingError> get errors => _errorCtrl.stream;

  Future<void> connect(String host, int port) async {
    _log('connect host=$host port=$port');
    await disconnect(intentional: true);
    _setState(WsState.connecting);
    _currentHost = host;
    _currentPort = port;
    try {
      final uri = Uri.parse('ws://$host:$port/ws');
      _channel = IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 20));
      _sub = _channel!.stream.listen(
        _onRaw,
        onError: (e) {
          _log('socket error: $e');
          _onClosed();
        },
        onDone: () {
          _log('socket done (close code=${_channel?.closeCode}, reason=${_channel?.closeReason})');
          _onClosed();
        },
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
      _log('connect threw: $e');
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

  Future<void> disconnect({bool intentional = true}) async {
    if (intentional) {
      _wasAuthed = false;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    await _sub?.cancel();
    _sub = null;
    if (_channel != null) {
      await _channel!.sink.close(ws_status.normalClosure);
      _channel = null;
    }
    if (intentional) {
      _currentHost = null;
      _currentPort = null;
    }
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

    if (env.type == MsgType.error) {
      final d = env.data ?? const {};
      final code = d['code']?.toString() ?? '';
      _log('server error: $code / ${d['message']}');
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
          tokens.setLastPeer(_currentHost!, _currentPort!);
        }
        _wasAuthed = true;
        _reconnectAttempts = 0;
        _setState(WsState.authed);
        _log('authed');
      } else if (code == 'locked') {
        _setState(WsState.locked);
        _errorCtrl.add(PairingError('locked', 'Too many wrong PINs; device locked for 60 s.'));
      } else if (needPin) {
        _setState(WsState.awaitingPin);
        if (code == 'invalid_pin') {
          _errorCtrl.add(PairingError('invalid_pin', 'Wrong PIN, try again.'));
        } else if (code == 'bad_token') {
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
    final host = _currentHost;
    final port = _currentPort;
    _setState(WsState.disconnected);

    // If we were authed and the user hasn't explicitly disconnected, try a few
    // automatic reconnects. Common causes covered:
    //   - server's "latest-wins" temporarily kicked us;
    //   - Wi-Fi roamed / momentarily dropped;
    //   - desktop process briefly restarted.
    if (_wasAuthed && host != null && port != null && _reconnectAttempts < _maxReconnects) {
      _reconnectAttempts++;
      final delayMs = 600 * _reconnectAttempts;
      _log('reconnect scheduled #$_reconnectAttempts in ${delayMs}ms');
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
        if (_state == WsState.disconnected) {
          connect(host, port).catchError((e) {
            _log('reconnect attempt failed: $e');
          });
        }
      });
    } else {
      _wasAuthed = false;
      _reconnectAttempts = 0;
    }
  }

  void _setState(WsState s) {
    if (_state == s) return;
    _log('state: $_state -> $s');
    _state = s;
    _stateCtrl.add(s);
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[WsClient] $msg');
  }

  void dispose() {
    _reconnectTimer?.cancel();
    disconnect(intentional: true);
    _stateCtrl.close();
    _msgCtrl.close();
    _errorCtrl.close();
  }
}
