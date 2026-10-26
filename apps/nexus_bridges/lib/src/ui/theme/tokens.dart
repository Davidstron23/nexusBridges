import 'package:flutter/material.dart';

final class NbColors extends ThemeExtension<NbColors> {
  const NbColors({
    required this.primary,
    required this.primaryHover,
    required this.primaryWeak,
    required this.primaryInk,
    required this.onPrimary,
    required this.hubTop,
    required this.hubBottom,
    required this.glow,
    required this.halo,
    required this.success,
    required this.successWeak,
    required this.onSuccessDisc,
    required this.netSurface,
    required this.netDiscTop,
    required this.netDiscBottom,
    required this.warning,
    required this.warningRing,
    required this.warningWeak,
    required this.danger,
    required this.dangerWeak,
    required this.ground,
    required this.card,
    required this.surfaceWeak,
    required this.track,
    required this.nodeTop,
    required this.nodeBottom,
    required this.border,
    required this.borderWeak,
    required this.text,
    required this.textWeak,
    required this.hint,
    required this.tooltip,
    required this.successInk,
    required this.primaryButton,
    required this.cardShadow,
    required this.popoverShadow,
    required this.discShadow,
    required this.nodeShadow,
  });

  final Color primary;
  final Color primaryHover;
  final Color primaryWeak;
  final Color primaryInk;
  final Color onPrimary;
  final Color hubTop;
  final Color hubBottom;
  final Color glow;
  final Color halo;
  final Color success;
  final Color successWeak;
  final Color onSuccessDisc;
  final Color netSurface;
  final Color netDiscTop;
  final Color netDiscBottom;
  final Color warning;
  final Color warningRing;
  final Color warningWeak;
  final Color danger;
  final Color dangerWeak;
  final Color ground;
  final Color card;
  final Color surfaceWeak;
  final Color track;
  final Color nodeTop;
  final Color nodeBottom;
  final Color border;
  final Color borderWeak;
  final Color text;
  final Color textWeak;
  final Color hint;
  final Color tooltip;
  final Color successInk;
  final Color primaryButton;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> popoverShadow;
  final List<BoxShadow> discShadow;
  final Color nodeShadow;

  static const NbColors light = NbColors(
    primary: Color(0xFF6D4AFF),
    primaryHover: Color(0xFF5B3AEB),
    primaryWeak: Color(0xFFEEEBFF),
    primaryInk: Color(0xFF5B3AEB),
    onPrimary: Color(0xFFFFFFFF),
    hubTop: Color(0xFF7B5CFF),
    hubBottom: Color(0xFF5A35F0),
    glow: Color.fromRGBO(109, 74, 255, 0.16),
    halo: Color.fromRGBO(109, 74, 255, 0.07),
    success: Color(0xFF178567),
    successWeak: Color(0xFFE2F4EC),
    onSuccessDisc: Color(0xFFFFFFFF),
    netSurface: Color(0xFFE2F4EB),
    netDiscTop: Color(0xFF22B08A),
    netDiscBottom: Color(0xFF127256),
    warning: Color(0xFFA35F00),
    warningRing: Color(0xFFFF9900),
    warningWeak: Color(0xFFFFF2DE),
    danger: Color(0xFFC2273F),
    dangerWeak: Color(0xFFFCE8EB),
    ground: Color(0xFFF3F2F7),
    card: Color(0xFFFFFFFF),
    surfaceWeak: Color(0xFFF4F3F8),
    track: Color(0xFFE9E7F0),
    nodeTop: Color(0xFFFFFFFF),
    nodeBottom: Color(0xFFF3F1FA),
    border: Color(0xFFDEDBE7),
    borderWeak: Color(0xFFECEAF2),
    text: Color(0xFF0C0C14),
    textWeak: Color(0xFF5A5766),
    hint: Color(0xFF8B8898),
    tooltip: Color(0xFF0C0C14),
    successInk: Color(0xFF127256),
    primaryButton: Color(0xFF6D4AFF),
    cardShadow: [
      BoxShadow(
        color: Color.fromRGBO(20, 14, 60, 0.05),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(20, 14, 60, 0.06),
        offset: Offset(0, 6),
        blurRadius: 18,
      ),
    ],
    popoverShadow: [
      BoxShadow(color: Color.fromRGBO(20, 14, 60, 0.08), spreadRadius: 1),
      BoxShadow(
        color: Color.fromRGBO(20, 14, 60, 0.18),
        offset: Offset(0, 18),
        blurRadius: 40,
      ),
    ],
    discShadow: [
      BoxShadow(
        color: Color.fromRGBO(18, 114, 86, 0.3),
        offset: Offset(0, 4),
        blurRadius: 10,
      ),
    ],
    nodeShadow: Color.fromRGBO(42, 31, 107, 0.16),
  );

  static const NbColors dark = NbColors(
    primary: Color(0xFF8A6EFF),
    primaryHover: Color(0xFF9D85FF),
    primaryWeak: Color.fromRGBO(138, 110, 255, 0.18),
    primaryInk: Color(0xFFA891FF),
    onPrimary: Color(0xFFFFFFFF),
    hubTop: Color(0xFF9479FF),
    hubBottom: Color(0xFF6D4AFF),
    glow: Color.fromRGBO(138, 110, 255, 0.24),
    halo: Color.fromRGBO(138, 110, 255, 0.06),
    success: Color(0xFF3DD6A9),
    successWeak: Color.fromRGBO(30, 168, 133, 0.16),
    onSuccessDisc: Color(0xFF1F1D27),
    netSurface: Color.fromRGBO(30, 168, 133, 0.16),
    netDiscTop: Color(0xFF5AE8BF),
    netDiscBottom: Color(0xFF1EA885),
    warning: Color(0xFFFFB547),
    warningRing: Color(0xFFFF9900),
    warningWeak: Color.fromRGBO(255, 153, 0, 0.14),
    danger: Color(0xFFFF6B82),
    dangerWeak: Color.fromRGBO(220, 50, 81, 0.18),
    ground: Color(0xFF16141C),
    card: Color(0xFF1F1D27),
    surfaceWeak: Color(0xFF292633),
    track: Color(0xFF33303F),
    nodeTop: Color(0xFF2F2C3B),
    nodeBottom: Color(0xFF262330),
    border: Color(0xFF3A3648),
    borderWeak: Color(0xFF2E2B39),
    text: Color(0xFFFFFFFF),
    textWeak: Color(0xFFB4B0C4),
    hint: Color(0xFF8E8A9E),
    tooltip: Color(0xFF0C0C14),
    successInk: Color(0xFF3DD6A9),
    primaryButton: Color(0xFF6D4AFF),
    cardShadow: [
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.3),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.25),
        offset: Offset(0, 6),
        blurRadius: 16,
      ),
    ],
    popoverShadow: [
      BoxShadow(color: Color(0xFF3A3648), spreadRadius: 1),
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.45),
        offset: Offset(0, 18),
        blurRadius: 40,
      ),
    ],
    discShadow: [
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.45),
        offset: Offset(0, 4),
        blurRadius: 12,
      ),
    ],
    nodeShadow: Color.fromRGBO(0, 0, 0, 0.5),
  );

  static NbColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NbColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  NbColors copyWith({
    Color? primary,
    Color? primaryHover,
    Color? primaryWeak,
    Color? primaryInk,
    Color? onPrimary,
    Color? hubTop,
    Color? hubBottom,
    Color? glow,
    Color? halo,
    Color? success,
    Color? successWeak,
    Color? onSuccessDisc,
    Color? netSurface,
    Color? netDiscTop,
    Color? netDiscBottom,
    Color? warning,
    Color? warningRing,
    Color? warningWeak,
    Color? danger,
    Color? dangerWeak,
    Color? ground,
    Color? card,
    Color? surfaceWeak,
    Color? track,
    Color? nodeTop,
    Color? nodeBottom,
    Color? border,
    Color? borderWeak,
    Color? text,
    Color? textWeak,
    Color? hint,
    Color? tooltip,
    Color? successInk,
    Color? primaryButton,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? popoverShadow,
    List<BoxShadow>? discShadow,
    Color? nodeShadow,
  }) {
    return NbColors(
      primary: primary ?? this.primary,
      primaryHover: primaryHover ?? this.primaryHover,
      primaryWeak: primaryWeak ?? this.primaryWeak,
      primaryInk: primaryInk ?? this.primaryInk,
      onPrimary: onPrimary ?? this.onPrimary,
      hubTop: hubTop ?? this.hubTop,
      hubBottom: hubBottom ?? this.hubBottom,
      glow: glow ?? this.glow,
      halo: halo ?? this.halo,
      success: success ?? this.success,
      successWeak: successWeak ?? this.successWeak,
      onSuccessDisc: onSuccessDisc ?? this.onSuccessDisc,
      netSurface: netSurface ?? this.netSurface,
      netDiscTop: netDiscTop ?? this.netDiscTop,
      netDiscBottom: netDiscBottom ?? this.netDiscBottom,
      warning: warning ?? this.warning,
      warningRing: warningRing ?? this.warningRing,
      warningWeak: warningWeak ?? this.warningWeak,
      danger: danger ?? this.danger,
      dangerWeak: dangerWeak ?? this.dangerWeak,
      ground: ground ?? this.ground,
      card: card ?? this.card,
      surfaceWeak: surfaceWeak ?? this.surfaceWeak,
      track: track ?? this.track,
      nodeTop: nodeTop ?? this.nodeTop,
      nodeBottom: nodeBottom ?? this.nodeBottom,
      border: border ?? this.border,
      borderWeak: borderWeak ?? this.borderWeak,
      text: text ?? this.text,
      textWeak: textWeak ?? this.textWeak,
      hint: hint ?? this.hint,
      tooltip: tooltip ?? this.tooltip,
      successInk: successInk ?? this.successInk,
      primaryButton: primaryButton ?? this.primaryButton,
      cardShadow: cardShadow ?? this.cardShadow,
      popoverShadow: popoverShadow ?? this.popoverShadow,
      discShadow: discShadow ?? this.discShadow,
      nodeShadow: nodeShadow ?? this.nodeShadow,
    );
  }

  @override
  NbColors lerp(ThemeExtension<NbColors>? other, double t) {
    if (other is! NbColors) return this;
    return t < 0.5 ? this : other;
  }
}
