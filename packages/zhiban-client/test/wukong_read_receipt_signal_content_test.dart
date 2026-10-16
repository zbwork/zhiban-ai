import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';

void main() {
  test('WkReadReceiptSignalContent decodes WuKong no_persist payload', () {
    final content = WkReadReceiptSignalContent().decodeJson({
      'type': WukongImClient.readReceiptSignalContentType,
      'version': 1,
      'kind': 'read_receipt.changed',
      'conversation_uuid': 'conv-1',
      'last_read_message_seq': 42,
      'reader_uid': 't_11_u_reader',
      'ts': '2026-06-16T10:00:00Z',
    }) as WkReadReceiptSignalContent;

    expect(content.contentType, WukongImClient.readReceiptSignalContentType);
    expect(content.kind, 'read_receipt.changed');
    expect(content.conversationUuid, 'conv-1');
    expect(content.lastReadMessageSeq, 42);
    expect(content.readerUid, 't_11_u_reader');
    expect(content.displayText(), isEmpty);
    expect(content.searchableWord(), isEmpty);
  });
}
