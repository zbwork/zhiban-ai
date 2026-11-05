import 'package:dio/dio.dart';

/// One execution owner per employee across chat, scheduled work and deletion.
class LocalEmployeeExecution {
  LocalEmployeeExecution({this.onChanged});
  final void Function()? onChanged;
  final _tokens = <String, CancelToken>{};
  bool _closed = false;

  bool busy(String employee) => _tokens.containsKey(employee);
  bool owns(String employee, CancelToken token) =>
      identical(_tokens[employee], token);

  CancelToken? acquire(String employee) {
    if (_closed || busy(employee)) return null;
    final token = CancelToken();
    _tokens[employee] = token;
    onChanged?.call();
    return token;
  }

  void release(String employee, CancelToken token) {
    if (!owns(employee, token)) return;
    _tokens.remove(employee);
    onChanged?.call();
  }

  void stop(String employee) => _tokens[employee]?.cancel();
  void dispose() {
    _closed = true;
    for (final token in _tokens.values) {
      token.cancel();
    }
  }
}
