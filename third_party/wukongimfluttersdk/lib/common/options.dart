import '../proto/proto.dart';

class Options {
  String? uid, token;
  String? addr; // connect address IP:PORT
  String? dbSuffix;
  // Optional stable app-provided device ID for CONNECT correlation.
  String? deviceID;
  int protoVersion = 0x04; // protocol version
  int deviceFlag = 0;
  bool debug = true;
  Function(Function(String addr) complete)?
      getAddr; // async get connect address
  Proto proto = Proto();
  Options();

  Options.newDefault(
    this.uid,
    this.token, {
    this.addr,
    this.dbSuffix,
    this.deviceID,
  });
}
