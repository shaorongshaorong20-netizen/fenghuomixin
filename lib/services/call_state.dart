import 'package:flutter/foundation.dart';

class CallState {
  CallState._();

  static final ValueNotifier<bool> isInCall = ValueNotifier<bool>(false);

  static void setInCall(bool value) {
    if (isInCall.value == value) return;
    isInCall.value = value;
  }
}
