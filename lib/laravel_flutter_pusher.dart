import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:json_annotation/json_annotation.dart';

part 'laravel_flutter_pusher.g.dart';

enum PusherConnectionState {
  // ignore: constant_identifier_names
  CONNECTING,
  // ignore: constant_identifier_names
  CONNECTED,
  // ignore: constant_identifier_names
  DISCONNECTING,
  // ignore: constant_identifier_names
  DISCONNECTED,
  // ignore: constant_identifier_names
  RECONNECTING,
  // ignore: constant_identifier_names
  RECONNECTING_WHEN_NETWORK_BECOMES_REACHABLE
}

class Channel {
  final String name;
  final LaravelFlutterPusher pusher;
  MethodChannel? _channel;

  Channel(
      {required this.name,
      required this.pusher,
      required MethodChannel channel}) {
    _channel = channel;
    _subscribe();
  }

  void _subscribe() async {
    var args = jsonEncode(
        BindArgs(instanceId: pusher._instanceId, channelName: name).toJson());
    await _channel!.invokeMethod('subscribe', args);
  }

  /// Bind to listen for events sent on the given channel
  Future bind(String eventName, Function onEvent) async {
    await pusher._bind(name, eventName, onEvent: onEvent);
  }

  Future unbind(String eventName) async {
    await pusher._unbind(name, eventName);
  }

  /// Trigger [eventName] (will be prefixed with "client-" in case you have not) for [Channel].
  ///
  /// Client events can only be triggered on private and presence channels because they require authentication
  /// You can only trigger a client event once a subscription has been successfully registered with Channels.
  // Future trigger(String eventName) async {
  //   if (!eventName.startsWith('client-')) {
  //     eventName = "client-$eventName";
  //   }

  //   await pusher._trigger(name, eventName);
  // }

  /// Once subscribed it is possible to trigger client events on a private
  /// channel as long as client events have been activated for the a Pusher
  /// application. There are a number of restrictions enforced with client
  /// events. For full details see the
  /// [documentation](http://pusher.com/docs/client_events)
  ///
  /// The [eventName] to trigger must have a `client-` prefix.
  Future<void> trigger(String eventName, dynamic data) async {
    if (!eventName.startsWith('client-')) {
      eventName = "client-$eventName";
    }

    await _channel!.invokeMethod(
      'trigger',
      jsonEncode({
        'eventName': eventName,
        'data': data.toString(),
        'channelName': name,
      }),
    );
  }
}

class LaravelFlutterPusher {
  static const MethodChannel _channel =
      MethodChannel('com.github.olubunmitosin/pusher');
  final EventChannel _eventChannel =
      const EventChannel('com.github.olubunmitosin/pusherStream');
  static int _instances = 0;

  int _instanceId = 0;
  String? _socketId;
  final Map<String, Function> _eventCallbacks = <String, Function>{};
  void Function(ConnectionError)? _onError;
  void Function(ConnectionStateChange)? _onConnectionStateChange;

  LaravelFlutterPusher(
    String appKey,
    PusherOptions options, {
    bool lazyConnect = false,
    bool enableLogging = false,
    void Function(ConnectionError)? onError,
    void Function(ConnectionStateChange)? onConnectionStateChange,
  }) {
    _instanceId = _instances++;
    _onError = onError;
    _onConnectionStateChange = onConnectionStateChange;
    _init(appKey, options, enableLogging: enableLogging);
    if (!lazyConnect) {
      connect(
          onError: onError, onConnectionStateChange: onConnectionStateChange);
    }
  }

  /// Connect the client to pusher
  Future connect({
    void Function(ConnectionStateChange)? onConnectionStateChange,
    void Function(ConnectionError)? onError,
  }) async {
    _onConnectionStateChange =
        onConnectionStateChange ?? _onConnectionStateChange;
    _onError = onError ?? _onError;

    await _channel.invokeMethod(
        'connect', jsonEncode({'instanceId': _instanceId}));
  }

  /// Disconnect the client from pusher
  Future disconnect() async {
    await _channel.invokeMethod(
        'disconnect', jsonEncode({'instanceId': _instanceId}));
  }

  /// Subscribe to a channel
  /// Use the returned [Channel] to bind events
  Channel subscribe(String channelName) {
    return Channel(name: channelName, pusher: this, channel: _channel);
  }

  /// Unsubscribe from a channel
  Future unsubscribe(String channelName) async {
    await _channel.invokeMethod('unsubscribe',
        jsonEncode({'channelName': channelName, 'instanceId': _instanceId}));
  }

  String? getSocketId() {
    return _socketId;
  }

  void _init(String appKey, PusherOptions options,
      {required bool enableLogging}) async {
    _eventChannel.receiveBroadcastStream().listen(_handleEvent);

    final initArgs = jsonEncode(InitArgs(
      _instanceId,
      appKey,
      options,
      isLoggingEnabled: enableLogging,
    ).toJson());

    await _channel.invokeMethod('init', initArgs);
  }

  void _handleEvent([dynamic arguments]) async {
    var message = PusherEventStreamMessage.fromJson(jsonDecode(arguments));

    if (message.instanceId != _instanceId.toString()) {
      return;
    }

    if (message.isEvent) {
      var callback =
          _eventCallbacks[message.event!.channel + message.event!.event];
      if (callback != null) {
        callback(jsonDecode(message.event!.data));
      }
    } else if (message.isConnectionStateChange) {
      _socketId = await _channel.invokeMethod(
          'getSocketId', jsonEncode({'instanceId': _instanceId}));
      if (_onConnectionStateChange != null) {
        _onConnectionStateChange!(message.connectionStateChange!);
      }
    } else if (message.isConnectionError) {
      if (_onError != null) {
        _onError!(message.connectionError!);
      }
    }
  }

  Future _bind(
    String channelName,
    String eventName, {
    required Function onEvent,
  }) async {
    final bindArgs = jsonEncode(BindArgs(
      instanceId: _instanceId,
      channelName: channelName,
      eventName: eventName,
    ).toJson());

    _eventCallbacks[channelName + eventName] = onEvent;
    await _channel.invokeMethod('bind', bindArgs);
  }

  Future _unbind(String channelName, String eventName) async {
    final bindArgs = jsonEncode(BindArgs(
      instanceId: _instanceId,
      channelName: channelName,
      eventName: eventName,
    ).toJson());

    _eventCallbacks.remove(channelName + eventName);
    await _channel.invokeMethod('unbind', bindArgs);
  }

  Future _trigger(String channelName, String eventName) async {
    final bindArgs = jsonEncode(BindArgs(
      instanceId: _instanceId,
      channelName: channelName,
      eventName: eventName,
    ).toJson());

    await _channel.invokeMethod('trigger', bindArgs);
  }
}

class PusherClient extends LaravelFlutterPusher {
  PusherClient(
    String appKey,
    PusherOptions options, {
    bool lazyConnect = false,
    bool enableLogging = false,
    void Function(ConnectionError)? onError,
    void Function(ConnectionStateChange)? onConnectionStateChange,
  }) : super(
          appKey,
          options,
          onError: onError,
          lazyConnect: lazyConnect,
          enableLogging: enableLogging,
          onConnectionStateChange: onConnectionStateChange,
        );
}

@JsonSerializable()
class BindArgs {
  final int instanceId;
  final String channelName;
  String? eventName;

  BindArgs(
      {required this.channelName, this.eventName, required this.instanceId});
  factory BindArgs.fromJson(Map<String, dynamic> json) =>
      _$BindArgsFromJson(json);
  Map<String, dynamic> toJson() => _$BindArgsToJson(this);
}

@JsonSerializable()
class InitArgs {
  final int instanceId;
  final String appKey;
  final PusherOptions options;
  final bool isLoggingEnabled;

  InitArgs(this.instanceId, this.appKey, this.options,
      {this.isLoggingEnabled = false});

  factory InitArgs.fromJson(Map<String, dynamic> json) =>
      _$InitArgsFromJson(json);

  Map<String, dynamic> toJson() => _$InitArgsToJson(this);
}

@JsonSerializable(includeIfNull: false)
class PusherOptions {
  PusherAuth? auth;
  String? cluster;
  final String host;
  final int port;
  final bool encrypted;
  final int activityTimeout;

  PusherOptions({
    this.auth,
    this.cluster,
    required this.host,
    this.port = 443,
    this.encrypted = false,
    this.activityTimeout = 30000,
  });

  factory PusherOptions.fromJson(Map<String, dynamic> json) =>
      _$PusherOptionsFromJson(json);

  Map<String, dynamic> toJson() => _$PusherOptionsToJson(this);
}

@JsonSerializable()
class PusherAuth {
  final String endpoint;
  final Map<String, String> headers;

  PusherAuth(
    this.endpoint, {
    this.headers = const {'Content-Type': 'application/x-www-form-urlencoded'},
  });

  factory PusherAuth.fromJson(Map<String, dynamic> json) =>
      _$PusherAuthFromJson(json);

  Map<String, dynamic> toJson() => _$PusherAuthToJson(this);
}

@JsonSerializable()
class PusherEventStreamMessage {
  Event? event;
  String? instanceId;
  ConnectionStateChange? connectionStateChange;
  ConnectionError? connectionError;

  bool get isEvent => event != null;

  bool get isConnectionStateChange => connectionStateChange != null;

  bool get isConnectionError => connectionError != null;

  PusherEventStreamMessage(
      {this.event,
      required this.instanceId,
      this.connectionStateChange,
      this.connectionError});

  factory PusherEventStreamMessage.fromJson(Map<String, dynamic> json) =>
      _$PusherEventStreamMessageFromJson(json);

  Map<String, dynamic> toJson() => _$PusherEventStreamMessageToJson(this);
}

@JsonSerializable()
class Event {
  final String channel;
  final String event;
  final String data;

  Event({required this.channel, required this.event, required this.data});

  factory Event.fromJson(Map<String, dynamic> json) => _$EventFromJson(json);

  Map<String, dynamic> toJson() => _$EventToJson(this);
}

@JsonSerializable()
class ConnectionStateChange {
  final String currentState;
  final String previousState;

  ConnectionStateChange(
      {required this.currentState, required this.previousState});

  factory ConnectionStateChange.fromJson(Map<String, dynamic> json) =>
      _$ConnectionStateChangeFromJson(json);

  Map<String, dynamic> toJson() => _$ConnectionStateChangeToJson(this);
}

@JsonSerializable()
class ConnectionError {
  final String message;
  final String code;
  final String exception;

  ConnectionError(
      {required this.message, required this.code, required this.exception});

  factory ConnectionError.fromJson(Map<String, dynamic> json) =>
      _$ConnectionErrorFromJson(json);

  Map<String, dynamic> toJson() => _$ConnectionErrorToJson(this);
}
