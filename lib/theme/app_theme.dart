import 'package:flutter/material.dart';

class AppTheme {
  static const Color _darkBackground = Color(0xFF080C14);
  static const Color _darkCard = Color(0xFF0F131E);
  static const Color _primary = Color(0xFFC62828);
  static const Color _secondary = Color(0xFFB8960C);
  static const Color _dividerDark = Color(0xFF1A1F2E);
  static const Color _textPrimaryDark = Color(0xFFE8E8E8);
  static const Color _textSecondaryDark = Color(0xFF8B8B8B);
  static const Color _textWeakDark = Color(0xFF555555);
  static const Color _inputFillDark = Color(0xFF141825);

  static const double _buttonRadius = 10;
  static const double _cardRadius = 16;

  static final ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _darkBackground,
    cardColor: _darkCard,
    colorScheme: const ColorScheme.dark(
      primary: _primary,
      secondary: _secondary,
      surface: _darkCard,
      onPrimary: Colors.white,
      onSecondary: Color(0xFF1A1A1A),
      onSurface: _textPrimaryDark,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: _darkCard,
      foregroundColor: _textPrimaryDark,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: const CardThemeData(
      color: _darkCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_cardRadius)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: _dividerDark,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _inputFillDark,
      hintStyle: const TextStyle(color: _textWeakDark),
      labelStyle: const TextStyle(color: _textSecondaryDark),
      floatingLabelStyle: const TextStyle(color: _secondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
        borderSide: const BorderSide(color: _dividerDark),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
        borderSide: const BorderSide(color: _dividerDark),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
        borderSide: const BorderSide(color: _secondary, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_buttonRadius),
        ),
      ),
    ),
    textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: _textPrimaryDark,
          displayColor: _textPrimaryDark,
        ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: _secondary,
      selectionColor: Color(0x55B8960C),
      selectionHandleColor: _secondary,
    ),
  );

  static final ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    cardColor: Colors.white,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primary,
      brightness: Brightness.light,
      primary: _primary,
      secondary: _secondary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF5F5F5),
      foregroundColor: Color(0xFF1A1A1A),
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_cardRadius)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFFFFFFF),
      hintStyle: const TextStyle(color: Color(0xFF6B6B6B)),
      labelStyle: const TextStyle(color: Color(0xFF6B6B6B)),
      floatingLabelStyle: const TextStyle(color: _secondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
        borderSide: const BorderSide(color: Color(0x22000000)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_buttonRadius),
        borderSide: const BorderSide(color: _primary, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_buttonRadius),
        ),
      ),
    ),
    textTheme: ThemeData.light().textTheme.apply(
          bodyColor: const Color(0xFF1A1A1A),
          displayColor: const Color(0xFF1A1A1A),
        ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: _primary,
      selectionColor: Color(0x33C62828),
      selectionHandleColor: _primary,
    ),
  );
}
