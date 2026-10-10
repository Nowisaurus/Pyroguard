class PasswordPolicy {
  static String? validate(String password) {
    if (password.length < 12) return 'Use at least 12 characters.';
    if (!RegExp(r'[A-Z]').hasMatch(password)) return 'Include an uppercase letter.';
    if (!RegExp(r'[a-z]').hasMatch(password)) return 'Include a lowercase letter.';
    if (!RegExp(r'[0-9]').hasMatch(password)) return 'Include a number.';
    if (!RegExp(r'[^A-Za-z0-9\s]').hasMatch(password)) return 'Include a special symbol.';
    if (RegExp(r'\s').hasMatch(password)) return 'Spaces are not permitted.';
    return null;
  }
}
