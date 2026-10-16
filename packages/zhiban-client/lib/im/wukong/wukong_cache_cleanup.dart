import 'package:sqflite/sqflite.dart';
import 'package:wukongimfluttersdk/type/const.dart';

/// Local eviction only: keep outgoing failed/pending messages for retry.
Future<void> clearWukongCachedRows(Database db) async {
  await db.transaction((tx) async {
    await tx.delete('message',
        where: 'status = ? AND message_seq > 0',
        whereArgs: [WKSendMsgResult.sendSuccess]);
    await tx.execute('DELETE FROM message_extra WHERE message_id NOT IN '
        "(SELECT message_id FROM message WHERE message_id IS NOT NULL)");
    await tx.execute('DELETE FROM message_reaction WHERE message_id NOT IN '
        "(SELECT message_id FROM message WHERE message_id IS NOT NULL)");
    await tx.execute('DELETE FROM conversation WHERE NOT EXISTS '
        '(SELECT 1 FROM message WHERE message.channel_id = conversation.channel_id '
        'AND message.channel_type = conversation.channel_type) '
        'AND NOT EXISTS (SELECT 1 FROM conversation_extra WHERE '
        'conversation_extra.channel_id = conversation.channel_id AND '
        'conversation_extra.channel_type = conversation.channel_type '
        "AND conversation_extra.draft <> '')");
    await tx.execute(
        "DELETE FROM conversation_extra WHERE draft = '' AND NOT EXISTS "
        '(SELECT 1 FROM conversation WHERE conversation.channel_id = conversation_extra.channel_id '
        'AND conversation.channel_type = conversation_extra.channel_type)');
  });
}
