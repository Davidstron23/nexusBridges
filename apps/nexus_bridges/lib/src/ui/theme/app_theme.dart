import 'package:flutter/material.dart';

import 'tokens.dart';

const Duration themeFade = Duration(milliseconds: 500);

const String _textFamily = 'Segoe UI Variable Text';
const String _displayFamily = 'Segoe UI Variable Display';
const List<String> _fallbackFamilies = ['Segoe UI'];

const ButtonStyle smallButton = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 28)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
);

abstract final class NbText {
  static const TextStyle title = TextStyle(
    fontFamily: _displayFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 20 / 15,
  );

  static const TextStyle titleNet = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 22 / 16,
  );

  static const TextStyle body = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 20 / 14,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 20 / 14,
  );

  static const TextStyle bodySm = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 18 / 13,
  );

  static const TextStyle button = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1,
  );

  static const TextStyle label = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 16 / 12,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 16 / 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle badge = TextStyle(
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 18 / 11,
  );

  static const TextStyle fileExt = TextStyle(
    fontFamily: _displayFamily,
    fontFamilyFallback: _fallbackFamilies,
    fontSize: 8.5,
    fontWeight: FontWeight.w700,
    height: 1,
  );
}

ThemeData buildTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? NbColors.dark : NbColors.light;
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  );
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.primaryButton,
    onPrimary: colors.onPrimary,
    secondary: colors.primary,
    onSecondary: colors.onPrimary,
    secondaryContainer: colors.primaryWeak,
    onSecondaryContainer: colors.primaryInk,
    error: colors.danger,
    onError: colors.onPrimary,
    surface: colors.card,
    onSurface: colors.text,
    onSurfaceVariant: colors.textWeak,
    surfaceContainerHighest: colors.surfaceWeak,
    outline: colors.border,
    outlineVariant: colors.borderWeak,
  );

  final commonButton = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(buttonShape),
    textStyle: const WidgetStatePropertyAll(NbText.button),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    iconSize: const WidgetStatePropertyAll(14),
    elevation: const WidgetStatePropertyAll(0),
  );

  Color? whenDisabled(Set<WidgetState> states, Color color) {
    return states.contains(WidgetState.disabled) ? color : null;
  }

  final outlined = commonButton.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return colors.surfaceWeak;
      if (states.contains(WidgetState.hovered)) return colors.surfaceWeak;
      return colors.card;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return colors.hint;
      return colors.text;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return BorderSide.none;
      if (states.contains(WidgetState.hovered)) {
        return BorderSide(color: colors.hint);
      }
      return BorderSide(color: colors.border);
    }),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return colors.text.withValues(alpha: 0.08);
      }
      return Colors.transparent;
    }),
  );

  final filled = commonButton.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => whenDisabled(states, colors.surfaceWeak),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => whenDisabled(states, colors.hint),
    ),
  );

  final ghost = commonButton.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return colors.surfaceWeak;
      if (states.contains(WidgetState.hovered)) return colors.primaryWeak;
      return Colors.transparent;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return colors.hint;
      return colors.primaryInk;
    }),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return colors.primaryInk.withValues(alpha: 0.08);
      }
      return Colors.transparent;
    }),
  );

  final textTheme = TextTheme(
    titleMedium: NbText.title.copyWith(color: colors.text),
    bodyMedium: NbText.body.copyWith(color: colors.text),
    bodySmall: NbText.caption.copyWith(color: colors.textWeak),
    labelLarge: NbText.button.copyWith(color: colors.text),
    labelMedium: NbText.label.copyWith(color: colors.text),
    labelSmall: NbText.badge.copyWith(color: colors.text),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    extensions: [colors],
    scaffoldBackgroundColor: colors.ground,
    visualDensity: VisualDensity.standard,
    fontFamily: _textFamily,
    fontFamilyFallback: _fallbackFamilies,
    colorScheme: scheme,
    textTheme: textTheme,
    cardTheme: CardThemeData(
      color: colors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: cardShape,
      surfaceTintColor: Colors.transparent,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
    filledButtonTheme: FilledButtonThemeData(style: filled),
    textButtonTheme: TextButtonThemeData(style: ghost),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.card,
      surfaceTintColor: Colors.transparent,
      shape: cardShape,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.card,
      surfaceTintColor: Colors.transparent,
      shape: cardShape,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.tooltip,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: NbText.bodySm.copyWith(color: colors.onPrimary),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.text,
      contentTextStyle: NbText.bodySm.copyWith(
        color: colors.card,
        fontWeight: FontWeight.w600,
      ),
      shape: buttonShape,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.track,
    ),
    dividerTheme: DividerThemeData(
      color: colors.borderWeak,
      thickness: 1,
      space: 1,
    ),
  );
}
