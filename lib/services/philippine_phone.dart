import 'package:flutter/services.dart';

/// Accepts Philippine mobile numbers written as 09XXXXXXXXX, 9XXXXXXXXX,
/// +639XXXXXXXXX, or 639XXXXXXXXX. BFP contact numbers may be landlines.
class PhilippinePhone {
  static String national(String value) {
    var digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('63') && digits.length >= 12) {
      digits = digits.substring(2);
    }
    if (digits.startsWith('0')) digits = digits.substring(1);
    return digits;
  }

  static bool mobile(String value) =>
      RegExp(r'^9[0-9]{9}$').hasMatch(national(value));

  static bool contact(String value) {
    final digits = national(value);
    return RegExp(r'^[0-9]{7,10}$').hasMatch(digits);
  }

  static String normalize(String value) {
    final digits = national(value);
    if (!contact(value)) {
      throw const FormatException(
          'Enter a valid Philippine contact number (7–10 digits after +63).');
    }
    return '+63$digits';
  }
}

class PhilippinePhoneFormatter extends TextInputFormatter {
  const PhilippinePhoneFormatter();
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (!newValue.composing.isCollapsed) return newValue;
    final digits = PhilippinePhone.national(newValue.text);
    if (digits.length > 10) return oldValue;
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}
