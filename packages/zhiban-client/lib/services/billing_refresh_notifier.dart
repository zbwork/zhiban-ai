import 'package:flutter/foundation.dart';

final billingSummaryRefreshNotifier = ValueNotifier<int>(0);

void notifyBillingSummaryChanged() {
  billingSummaryRefreshNotifier.value += 1;
}
