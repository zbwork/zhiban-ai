import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:wukongimfluttersdk/db/const.dart';

import 'package:wukongimfluttersdk/db/wk_db_helper.dart';
import 'package:wukongimfluttersdk/entity/channel.dart';
import 'package:wukongimfluttersdk/entity/channel_member.dart';
import 'package:wukongimfluttersdk/entity/msg.dart';
import 'package:wukongimfluttersdk/proto/write_read.dart';
import 'package:wukongimfluttersdk/wkim.dart';
import 'package:wukongimfluttersdk/common/crypto_utils.dart';
import '../common/logs.dart';
import '../entity/conversation.dart';
import '../proto/packet.dart';
import '../proto/proto.dart';
import '../type/const.dart';

class _WKSocket {
  Socket? _socket;
  WebSocket? _webSocket;
  bool _isListening = false;
  _WKSocket._internal({Socket? socket, WebSocket? webSocket})
      : _socket = socket,
        _webSocket = webSocket;

  factory _WKSocket.newSocket(Socket socket) {
    return _WKSocket._internal(socket: socket);
  }

  factory _WKSocket.newWebSocket(WebSocket webSocket) {
    return _WKSocket._internal(webSocket: webSocket);
  }

  void close() {
    _isListening = false;
    try {
      final socket = _socket;
      final webSocket = _webSocket;
      if (socket != null) unawaited(socket.close());
      if (webSocket != null) unawaited(webSocket.close());
    } finally {
      _socket = null;
      _webSocket = null;
    }
  }

  send(Uint8List data) {
    try {
      if (_socket?.remotePort != null) {
        _socket?.add(data); // 使用安全调用操作符
        return _socket?.flush();
      }
      if (_webSocket?.readyState == WebSocket.open) {
        _webSocket?.add(data);
        return;
      }
    } catch (e) {
      Logs.debug('发送消息错误$e');
    }
  }

  String _debugHead(Uint8List bytes, {int limit = 32}) {
    return bytes
        .take(limit)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }

  void listen(void Function(Uint8List data) onData, void Function() error) {
    if (!_isListening && _socket != null) {
      _socket!.listen(
        onData,
        onError: (err) {
          Logs.debug('socket断开了${err.toString()}');
          error();
        },
        onDone: () {
          error();
        },
      );
      _isListening = true;
    } else if (!_isListening && _webSocket != null) {
      _webSocket!.listen(
        (dynamic data) {
          Uint8List? bytes;
          if (data is Uint8List) {
            bytes = data;
          } else if (data is List<int>) {
            bytes = Uint8List.fromList(data);
          } else if (data is String) {
            bytes = Uint8List.fromList(utf8.encode(data));
          }
          if (bytes == null) {
            Logs.debug('websocket收到未知帧 type=${data.runtimeType}');
            return;
          }
          Logs.debug(
            'websocket收到帧 type=${data.runtimeType} len=${bytes.length} head=${_debugHead(bytes)}',
          );
          onData(bytes);
        },
        onError: (err) {
          Logs.debug('websocket断开了${err.toString()}');
          error();
        },
        onDone: () {
          error();
        },
      );
      _isListening = true;
    }
  }
}

class WKConnectionManager {
  WKConnectionManager._privateConstructor();
  static final WKConnectionManager _instance =
      WKConnectionManager._privateConstructor();
  static WKConnectionManager get shared => _instance;

  /// 兼容旧调用方的只读语义；连接归属由 generation 判断，不再用该全局布尔值
  /// 区分“主动关闭”和“异常关闭”。
  bool isDisconnection = false;
  bool isReconnection = false;
  bool isNetworkUnavailable = false;
  Timer? heartTimer;
  Timer? checkNetworkTimer;
  final heartIntervalSecond = const Duration(seconds: 60);
  final checkNetworkSecond = const Duration(seconds: 1);

  /// 生产固定 5 秒，短于上层 8 秒 connecting watchdog；公开仅供窄测缩短等待。
  @visibleForTesting
  Duration webSocketConnectTimeout = const Duration(seconds: 5);

  /// 默认使用 dart:io；可控 Future 仅供验证超时后的迟到 socket 隔离。
  @visibleForTesting
  Future<WebSocket> Function(String url) webSocketConnector = WebSocket.connect;
  int unReceivePongCount = 0;
  final LinkedHashMap<int, SendingMsg> _sendingMsgMap = LinkedHashMap();
  HashMap<String, Function(int, int?, ConnectionInfo?)>? _connectionListenerMap;
  _WKSocket? _socket;
  int _connectionGeneration = 0;
  bool _isConnecting = false;
  bool _isConnected = false;
  ConnectivityResult? lastConnectivityResult;
  final Connectivity _connectivity = Connectivity();

  addOnConnectionStatus(String key, Function(int, int?, ConnectionInfo?) back) {
    _connectionListenerMap ??= HashMap();
    _connectionListenerMap![key] = back;
  }

  removeOnConnectionStatus(String key) {
    if (_connectionListenerMap != null) {
      _connectionListenerMap!.remove(key);
    }
  }

  setConnectionStatus(int status, {int? reasoncode, ConnectionInfo? info}) {
    if (_connectionListenerMap != null) {
      _connectionListenerMap!.forEach((key, back) {
        back(status, reasoncode, info);
      });
    }
  }

  void connect() {
    var addr = WKIM.shared.options.addr;
    if ((addr == null || addr == "") && WKIM.shared.options.getAddr == null) {
      Logs.info("没有配置addr！");
      return;
    }
    if (WKIM.shared.options.uid == "" ||
        WKIM.shared.options.uid == null ||
        WKIM.shared.options.token == "" ||
        WKIM.shared.options.token == null) {
      Logs.error("没有初始化uid或token");
      return;
    }
    // connect 只代表一次底层连接尝试。重试策略由上层 ConversationRealtimeBridge
    // 统一拥有，避免 SDK timer 与业务层 timer 互相放大。
    if (_isConnecting || _isConnected) {
      Logs.debug(
          '忽略重复connect: connecting=$_isConnecting connected=$_isConnected');
      return;
    }
    // 显式 connect 是上层重试决策，不能被上一轮探测的离线标志短路。
    // 真正仍离线时由 socket 失败回调交回上层退避，不在 SDK 内另起重试。
    isNetworkUnavailable = false;
    final generation = ++_connectionGeneration;
    _isConnecting = true;
    _isConnected = false;
    isDisconnection = false;
    isReconnection = false;
    _cacheData = null;
    // 网络快照属于连接代次；旧 none/wifi 不能把新连接误判为网络切换。
    lastConnectivityResult = null;
    _closeSocketAndTimers();
    setConnectionStatus(WKConnectStatus.connecting);
    if (WKIM.shared.options.getAddr != null) {
      WKIM.shared.options.getAddr!((String addr) {
        if (!_isCurrentGeneration(generation)) return;
        _socketConnect(addr, generation);
      });
    } else {
      _socketConnect(addr!, generation);
    }
  }

  Future<void> disconnect(bool isLogout) async {
    isDisconnection = true;
    isReconnection = false;
    isNetworkUnavailable = false;
    _invalidateCurrentConnection(WKConnectStatus.fail);
    if (isLogout) {
      await _clearLoginState();
    }
  }

  bool _isCurrentGeneration(int generation) =>
      generation == _connectionGeneration;

  void _socketConnect(String addr, int generation) {
    if (!_isCurrentGeneration(generation)) return;
    Logs.info("连接地址--->$addr");
    if (addr == '') {
      _connectFail('连接地址为空', generation);
      return;
    }
    if (addr.startsWith('ws://') || addr.startsWith('wss://')) {
      _webSocketConnect(addr, generation);
      return;
    }
    var addrs = addr.split(":");
    var host = addrs[0];
    var port = addrs[1];
    try {
      Socket.connect(host, int.parse(port), timeout: const Duration(seconds: 5))
          .then((socket) {
        if (!_isCurrentGeneration(generation)) {
          unawaited(socket.close());
          return;
        }
        _socket = _WKSocket.newSocket(socket);
        _connectSuccess(generation);
      }).catchError((err) {
        _connectFail(err, generation);
      }).onError((err, stackTrace) {
        _connectFail(err, generation);
      });
    } catch (e) {
      _connectFail(e, generation);
    }
  }

  void _webSocketConnect(String addr, int generation) {
    Timer? timeoutTimer;
    try {
      timeoutTimer = Timer(webSocketConnectTimeout, () {
        _connectFail(
          TimeoutException(
            'WebSocket connect timed out after '
            '${webSocketConnectTimeout.inMilliseconds}ms',
          ),
          generation,
        );
      });
      unawaited(webSocketConnector(addr).then<void>((socket) {
        timeoutTimer?.cancel();
        if (!_isCurrentGeneration(generation)) {
          // Future.timeout 无法取消底层握手；显式接住迟到 socket 并关闭，
          // 避免旧连接在 watchdog 已启动新 generation 后泄漏。
          unawaited(socket.close());
          return;
        }
        _socket = _WKSocket.newWebSocket(socket);
        _connectSuccess(generation);
      }, onError: (Object err, StackTrace stackTrace) {
        timeoutTimer?.cancel();
        _connectFail(err, generation);
      }));
    } catch (e) {
      timeoutTimer?.cancel();
      _connectFail(e, generation);
    }
  }

  // socket 连接成功
  void _connectSuccess(int generation) {
    if (!_isCurrentGeneration(generation)) return;
    // 监听消息
    _socket?.listen(
      (Uint8List data) {
        if (!_isCurrentGeneration(generation)) return;
        try {
          _cutDatas(data, generation: generation);
        } catch (e, stackTrace) {
          final head = data
              .take(32)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
          Logs.error(
            'WuKong WS解包失败 len=${data.length} head=$head error=$e stack=$stackTrace',
          );
          _cacheData = null;
          _failCurrentConnection(generation, 'WuKong WS解包失败: $e');
        }
        // _decodePacket(data);
      },
      () {
        _failCurrentConnection(generation, 'socket closed');
      },
    );
    // 发送连接包
    unawaited(_sendConnectPacket(generation));
  }

  void _connectFail(Object? error, int generation) {
    if (!_isCurrentGeneration(generation)) return;
    Logs.error('连接失败: ${error.toString()}');
    _invalidateCurrentConnection(WKConnectStatus.fail);
  }

  testCutData(Uint8List data) {
    _cutDatas(data, generation: _connectionGeneration);
  }

  Uint8List? _cacheData;
  void _cutDatas(Uint8List data, {required int generation}) {
    if (!_isCurrentGeneration(generation)) return;
    if (_cacheData == null || _cacheData!.isEmpty) {
      _cacheData = data;
    } else {
      // 上次存在未解析完的消息
      Uint8List temp = Uint8List(_cacheData!.length + data.length);
      for (var i = 0; i < _cacheData!.length; i++) {
        temp[i] = _cacheData![i];
      }
      for (var i = 0; i < data.length; i++) {
        temp[i + _cacheData!.length] = data[i];
      }
      _cacheData = temp;
    }
    Uint8List lastMsgBytes = _cacheData!;
    int readLength = 0;
    while (lastMsgBytes.isNotEmpty && readLength != lastMsgBytes.length) {
      readLength = lastMsgBytes.length;
      ReadData readData = ReadData(lastMsgBytes);
      var b = readData.readUint8();
      var packetType = b >> 4;
      if (PacketType.values[(b >> 4)] == PacketType.pong) {
        Logs.debug('pong');
        unReceivePongCount = 0;
        Uint8List bytes = lastMsgBytes.sublist(1, lastMsgBytes.length);
        _cacheData = lastMsgBytes = bytes;
      } else {
        if (packetType < 10) {
          if (lastMsgBytes.length < 5) {
            _cacheData = lastMsgBytes;
            break;
          }
          int remainingLength = readData.readVariableLength();
          if (remainingLength == -1) {
            //剩余长度被分包
            _cacheData = lastMsgBytes;
            break;
          }
          if (remainingLength > 1 << 21) {
            _cacheData = null;
            break;
          }
          List<int> bytes = encodeVariableLength(remainingLength);

          if (remainingLength + 1 + bytes.length > lastMsgBytes.length) {
            //半包情况
            _cacheData = lastMsgBytes;
          } else {
            Uint8List msg = lastMsgBytes.sublist(
              0,
              remainingLength + 1 + bytes.length,
            );
            _decodePacket(msg, generation);
            Uint8List temps = lastMsgBytes.sublist(
              msg.length,
              lastMsgBytes.length,
            );
            _cacheData = lastMsgBytes = temps;
          }
        } else {
          _cacheData = null;
          _failCurrentConnection(
              generation, 'invalid packet type: $packetType');
          break;
        }
      }
    }
  }

  void _decodePacket(Uint8List data, int generation) {
    if (!_isCurrentGeneration(generation)) return;
    var packet = WKIM.shared.options.proto.decode(data);
    Logs.debug('解码出包->$packet');
    unReceivePongCount = 0;
    if (packet.header.packetType == PacketType.connack) {
      var connackPacket = packet as ConnackPacket;
      if (connackPacket.reasonCode == 1) {
        Logs.debug('连接成功！');
        _isConnecting = false;
        _isConnected = true;
        WKIM.shared.options.protoVersion = connackPacket.serviceProtoVersion;
        CryptoUtils.setServerKeyAndSalt(
          connackPacket.serverKey,
          connackPacket.salt,
        );
        setConnectionStatus(
          WKConnectStatus.success,
          reasoncode: connackPacket.reasonCode,
          info: ConnectionInfo(connackPacket.nodeId),
        );
        // Future.delayed(Duration(seconds: 1), () {

        // });
        try {
          WKIM.shared.conversationManager.setSyncConversation(() {
            if (!_isCurrentGeneration(generation) || !_isConnected) return;
            setConnectionStatus(WKConnectStatus.syncCompleted);
            _resendMsg();
          });
        } catch (e) {
          Logs.error(e.toString());
        }

        _startHeartTimer(generation);
        _startCheckNetworkTimer(generation);
      } else {
        Logs.debug('连接失败！错误->${connackPacket.reasonCode}');
        _invalidateCurrentConnection(
          WKConnectStatus.fail,
          reasonCode: connackPacket.reasonCode,
        );
      }
    } else if (packet.header.packetType == PacketType.recv) {
      Logs.debug('收到消息');
      var recvPacket = packet as RecvPacket;
      _verifyRecvMsg(recvPacket);
      if (!recvPacket.header.noPersist) {
        _sendReceAckPacket(
          recvPacket.messageID,
          recvPacket.messageSeq,
          recvPacket.header,
        );
      }
    } else if (packet.header.packetType == PacketType.sendack) {
      var sendack = packet as SendAckPacket;
      Logs.debug('发送结果：${sendack.reasonCode}');
      WKIM.shared.messageManager.updateSendResult(
        sendack.messageID,
        sendack.clientSeq,
        sendack.messageSeq,
        sendack.reasonCode,
      );
      if (_sendingMsgMap.containsKey(sendack.clientSeq)) {
        _sendingMsgMap[sendack.clientSeq]!.isCanResend = false;
      }
    } else if (packet.header.packetType == PacketType.disconnect) {
      _invalidateCurrentConnection(WKConnectStatus.kicked);
      unawaited(
        _clearLoginState().catchError((Object error, StackTrace stackTrace) {
          Logs.error('服务端断开连接后的本地清理失败: $error\n$stackTrace');
        }),
      );
    } else if (packet.header.packetType == PacketType.pong) {
      Logs.info('pong...');
    }
  }

  Future<void> _clearLoginState() async {
    WKIM.shared.options.uid = '';
    WKIM.shared.options.token = '';
    try {
      await WKIM.shared.messageManager.updateSendingMsgFail();
    } finally {
      await WKDBHelper.shared.close();
    }
  }

  void _failCurrentConnection(int generation, Object error) {
    if (!_isCurrentGeneration(generation)) return;
    if (isDisconnection) {
      Logs.debug('忽略主动断开连接的迟到回调: generation=$generation');
      return;
    }
    Logs.error('连接已断开: $error');
    _invalidateCurrentConnection(WKConnectStatus.fail);
  }

  void _invalidateCurrentConnection(
    int status, {
    int? reasonCode,
    bool keepNetworkTimer = false,
  }) {
    // 先使旧 generation 失效，再关闭 socket；关闭产生的 onDone/onError
    // 因 generation 不匹配而不能影响下一条连接。
    _connectionGeneration++;
    _isConnecting = false;
    _isConnected = false;
    _cacheData = null;
    _closeSocketAndTimers(keepNetworkTimer: keepNetworkTimer);
    setConnectionStatus(status, reasoncode: reasonCode);
  }

  void _closeSocketAndTimers({bool keepNetworkTimer = false}) {
    if (!keepNetworkTimer) _stopCheckNetworkTimer();
    _stopHeartTimer();
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  _sendReceAckPacket(BigInt messageID, int messageSeq, PacketHeader header) {
    RecvAckPacket ackPacket = RecvAckPacket();
    ackPacket.header.noPersist = header.noPersist;
    ackPacket.header.syncOnce = header.syncOnce;
    ackPacket.header.showUnread = header.showUnread;
    ackPacket.messageID = messageID;
    ackPacket.messageSeq = messageSeq;
    _sendPacket(ackPacket);
  }

  Future<void> _sendConnectPacket(int generation) async {
    CryptoUtils.init();
    var deviceID = await _getDeviceID();
    if (!_isCurrentGeneration(generation)) return;
    var connectPacket = ConnectPacket(
      uid: WKIM.shared.options.uid!,
      token: WKIM.shared.options.token!,
      version: WKIM.shared.options.protoVersion,
      clientKey: base64Encode(CryptoUtils.dhPublicKey!),
      deviceID: deviceID,
      clientTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
    connectPacket.deviceFlag = WKIM.shared.deviceFlagApp;
    _sendPacket(connectPacket);
  }

  _sendPacket(Packet packet) async {
    var data = WKIM.shared.options.proto.encode(packet);
    if (!isReconnection) {
      await _socket?.send(data);
    }
  }

  void _startCheckNetworkTimer(int generation) {
    _stopCheckNetworkTimer();
    checkNetworkTimer = Timer.periodic(checkNetworkSecond, (timer) {
      var connectivityResult = _connectivity.checkConnectivity();
      connectivityResult.then((value) {
        if (!_isCurrentGeneration(generation) && !isNetworkUnavailable) {
          timer.cancel();
          if (identical(checkNetworkTimer, timer)) checkNetworkTimer = null;
          return;
        }
        /**
         * 经过查阅 connectivity_plus 官方文档和源码确认：
          checkConnectivity() 返回的 List<ConnectivityResult> 中，ConnectivityResult.none 只会单独出现，不会和其他连接类型（如 wifi、mobile）混合在同一个列表中。官方文档原文：
          "The returned list is never empty. In case of no connectivity, the list contains a single element of [ConnectivityResult.none]. Note also that this is the only case where
          ConnectivityResult.none is present."
          参考链接：
          - https://pub.dev/documentation/connectivity_plus_platform_interface/latest/connectivity_plus_platform_interface/ConnectivityResult.html
          - https://github.com/fluttercommunity/plus_plugins/blob/main/packages/connectivity_plus/connectivity_plus/lib/connectivity_plus.dart
          所以 value.contains(ConnectivityResult.none) 在真机上的判断是可靠的，不会出现混合值误触发的情况。
          如果你是在模拟器上遇到反复触发"网络断开了"的问题，这通常是模拟器本身网络状态不稳定导致的，建议在真机上验证一下。
        */
        if (value.contains(ConnectivityResult.none)) {
          if (!isNetworkUnavailable) {
            isReconnection = true;
            isNetworkUnavailable = true;
            Logs.debug('网络断开了');
            _checkSedingMsg();
            _invalidateCurrentConnection(
              WKConnectStatus.noNetwork,
              keepNetworkTimer: true,
            );
          }
          lastConnectivityResult = ConnectivityResult.none;
        } else {
          final recovered = isNetworkUnavailable;
          isNetworkUnavailable = false;
          final networkChanged = !recovered &&
              lastConnectivityResult != null &&
              !value.contains(lastConnectivityResult);
          if (recovered) {
            isReconnection = false;
            _stopCheckNetworkTimer();
            // 网络恢复只上报可重试状态；真正的连接调度由 bridge 负责。
            setConnectionStatus(WKConnectStatus.fail);
          } else if (networkChanged && (_isConnecting || _isConnected)) {
            isReconnection = false;
            _invalidateCurrentConnection(WKConnectStatus.fail);
          }
        }
        if (value.isNotEmpty) {
          lastConnectivityResult = value[0];
        }
      });
    });
  }

  _stopCheckNetworkTimer() {
    // if (_connectivitySubscription != null) {
    // _connectivitySubscription?.cancel();
    // }
    if (checkNetworkTimer != null) {
      checkNetworkTimer!.cancel();
      checkNetworkTimer = null;
    }
  }

  void _startHeartTimer(int generation) {
    _stopHeartTimer();
    heartTimer = Timer.periodic(heartIntervalSecond, (timer) {
      if (unReceivePongCount > 0) {
        Logs.debug('心跳包未收到pong，连接失败');
        isReconnection = false;
        _failCurrentConnection(generation, 'heartbeat pong timeout');
        return;
      }
      Logs.info('ping...');
      unReceivePongCount++;
      _sendPacket(PingPacket());
    });
  }

  _stopHeartTimer() {
    if (heartTimer != null) {
      heartTimer!.cancel();
      heartTimer = null;
    }
  }

  sendMessage(WKMsg wkMsg) {
    SendPacket packet = SendPacket();
    packet.setting = wkMsg.setting;
    packet.header.noPersist = wkMsg.header.noPersist;
    packet.header.showUnread = wkMsg.header.redDot;
    packet.header.syncOnce = wkMsg.header.syncOnce;
    packet.channelID = wkMsg.channelID;
    packet.channelType = wkMsg.channelType;
    packet.clientSeq = wkMsg.clientSeq;
    packet.clientMsgNO = wkMsg.clientMsgNO;
    packet.topic = wkMsg.topicID;
    packet.expire = wkMsg.expireTime;
    packet.payload = wkMsg.content;
    _addSendingMsg(packet);
    _sendPacket(packet);
  }

  _verifyRecvMsg(RecvPacket recvMsg) {
    StringBuffer sb = StringBuffer();
    sb.writeAll([
      recvMsg.messageID,
      recvMsg.messageSeq,
      recvMsg.clientMsgNO,
      recvMsg.messageTime,
      recvMsg.fromUID,
      recvMsg.channelID,
      recvMsg.channelType,
      recvMsg.payload,
    ]);
    var encryptContent = sb.toString();
    var result = CryptoUtils.aesEncrypt(encryptContent);
    String localMsgKey = CryptoUtils.generateMD5(result);
    if (recvMsg.msgKey != localMsgKey) {
      Logs.error('非法消息-->期望msgKey：$localMsgKey，实际msgKey：${recvMsg.msgKey}');
      return;
    } else {
      recvMsg.payload = CryptoUtils.aesDecrypt(recvMsg.payload);
      Logs.debug(recvMsg.toString());
      _saveRecvMsg(recvMsg);
    }
  }

  _saveRecvMsg(RecvPacket recvMsg) async {
    WKMsg msg = WKMsg();
    msg.header.redDot = recvMsg.header.showUnread;
    msg.header.noPersist = recvMsg.header.noPersist;
    msg.header.syncOnce = recvMsg.header.syncOnce;
    msg.setting = recvMsg.setting;
    msg.channelType = recvMsg.channelType;
    msg.channelID = recvMsg.channelID;
    msg.content = recvMsg.payload;
    msg.messageID = recvMsg.messageID.toString();
    msg.messageSeq = recvMsg.messageSeq;
    msg.timestamp = recvMsg.messageTime;
    msg.fromUID = recvMsg.fromUID;
    msg.clientMsgNO = recvMsg.clientMsgNO;
    msg.expireTime = recvMsg.expire;
    if (msg.expireTime > 0) {
      msg.expireTimestamp = msg.expireTime + msg.timestamp;
    }
    msg.status = WKSendMsgResult.sendSuccess;
    msg.topicID = recvMsg.topic;
    msg.orderSeq = await WKIM.shared.messageManager.getMessageOrderSeq(
      msg.messageSeq,
      msg.channelID,
      msg.channelType,
    );
    dynamic contentJson = jsonDecode(msg.content);
    msg.contentType = WKDBConst.readInt(contentJson, 'type');
    msg.isDeleted = _isDeletedMsg(contentJson);
    msg.messageContent = WKIM.shared.messageManager.getMessageModel(
      msg.contentType,
      contentJson,
    );
    WKChannel? fromChannel = await WKIM.shared.channelManager.getChannel(
      msg.fromUID,
      WKChannelType.personal,
    );
    if (fromChannel != null) {
      msg.setFrom(fromChannel);
    }
    if (msg.channelType == WKChannelType.group) {
      WKChannelMember? memberChannel = await WKIM.shared.channelMemberManager
          .getMember(msg.channelID, WKChannelType.group, msg.fromUID);
      if (memberChannel != null) {
        msg.setMemberOfFrom(memberChannel);
      }
    }
    WKIM.shared.messageManager.parsingMsg(msg);
    if (msg.isDeleted == 0 &&
        !msg.header.noPersist &&
        msg.contentType != WkMessageContentType.insideMsg) {
      int row = await WKIM.shared.messageManager.saveMsg(msg);
      msg.clientSeq = row;
      WKUIConversationMsg? uiMsg = await WKIM.shared.conversationManager
          .saveWithLiMMsg(msg, msg.header.redDot ? 1 : 0);
      if (uiMsg != null) {
        List<WKUIConversationMsg> list = [];
        list.add(uiMsg);
        WKIM.shared.conversationManager.setRefreshUIMsgs(list);
      }
    } else {
      Logs.debug(
        '消息不能存库:is_deleted=${msg.isDeleted},no_persist=${msg.header.noPersist},content_type:${msg.contentType}',
      );
    }
    if (msg.contentType != WkMessageContentType.insideMsg) {
      List<WKMsg> list = [];
      list.add(msg);
      WKIM.shared.messageManager.pushNewMsg(list);
    }
  }

  int _isDeletedMsg(dynamic jsonObject) {
    int isDelete = 0;
    if (jsonObject != null) {
      var visibles = jsonObject['visibles'];
      if (visibles != null && visibles is List) {
        bool isIncludeLoginUser = false;
        for (int i = 0, size = visibles.length; i < size; i++) {
          if (visibles[i] == WKIM.shared.options.uid) {
            isIncludeLoginUser = true;
            break;
          }
        }
        isDelete = isIncludeLoginUser ? 0 : 1;
      }
    }
    return isDelete;
  }

  _resendMsg() async {
    _removeSendingMsg();
    if (_sendingMsgMap.isNotEmpty) {
      for (var entry in _sendingMsgMap.entries) {
        if (entry.value.isCanResend) {
          Logs.debug("重发消息：${entry.value.sendPacket.clientSeq}");
          await _sendPacket(entry.value.sendPacket);
        }
      }
    }
  }

  _addSendingMsg(SendPacket sendPacket) {
    _removeSendingMsg();
    _sendingMsgMap[sendPacket.clientSeq] = SendingMsg(sendPacket);
  }

  _removeSendingMsg() {
    if (_sendingMsgMap.isNotEmpty) {
      List<int> ids = [];
      _sendingMsgMap.forEach((key, sendingMsg) {
        if (!sendingMsg.isCanResend) {
          ids.add(key);
        }
      });
      if (ids.isNotEmpty) {
        for (var i = 0; i < ids.length; i++) {
          _sendingMsgMap.remove(ids[i]);
        }
      }
    }
  }

  _checkSedingMsg() {
    if (_sendingMsgMap.isNotEmpty) {
      final it = _sendingMsgMap.entries.iterator;
      while (it.moveNext()) {
        var key = it.current.key;
        var wkSendingMsg = it.current.value;
        if (wkSendingMsg.sendCount == 5 && wkSendingMsg.isCanResend) {
          WKIM.shared.messageManager.updateMsgStatusFail(key);
          wkSendingMsg.isCanResend = false;
        } else {
          var nowTime =
              (DateTime.now().millisecondsSinceEpoch / 1000).truncate();
          if (nowTime - wkSendingMsg.sendTime > 10) {
            wkSendingMsg.sendTime =
                (DateTime.now().millisecondsSinceEpoch / 1000).truncate();
            wkSendingMsg.sendCount++;
            _sendingMsgMap[key] = wkSendingMsg;
            _sendPacket(wkSendingMsg.sendPacket);
            Logs.debug("消息发送失败，尝试重发中...");
          }
        }
      }

      _removeSendingMsg();
    }
  }
}

Future<String> _getDeviceID() async {
  final configuredDeviceID = WKIM.shared.options.deviceID?.trim() ?? '';
  if (configuredDeviceID.isNotEmpty) {
    return configuredDeviceID;
  }
  SharedPreferences preferences = await SharedPreferences.getInstance();
  String wkUid = WKIM.shared.options.uid!;
  String key = "${wkUid}_device_id";
  var deviceID = preferences.getString(key);
  if (deviceID == null || deviceID == "") {
    deviceID = const Uuid().v4().toString().replaceAll("-", "");
    preferences.setString(key, deviceID);
  }
  return "${deviceID}F";
}

class SendingMsg {
  SendPacket sendPacket;
  int sendCount = 0;
  int sendTime = 0;
  bool isCanResend = true;
  SendingMsg(this.sendPacket) {
    sendTime = (DateTime.now().millisecondsSinceEpoch / 1000).truncate();
  }
}

class ConnectionInfo {
  int nodeId;
  ConnectionInfo(this.nodeId);
}
