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
    required this.primaryButtonHover,
    required this.dangerFill,
    required this.ice,
    required this.iceWeak,
    required this.scrim,
    required this.segment,
    required this.keyFill,
    required this.keyShadow,
    required this.keyOkBorder,
    required this.okShadow,
    required this.sheen,
    required this.neutralWeak,
    required this.stageBorder,
    required this.stageTrack,
    required this.stageWeak,
    required this.stageHint,
    required this.stageDashedRing,
    required this.discTint,
    required this.haloOpacity,
    required this.primaryButtonShadow,
    required this.primaryButtonHoverShadow,
    required this.dangerButtonHoverShadow,
    required this.buttonHighlight,
    required this.buttonHighlightHover,
    required this.headingWeight,
    required this.menuSurface,
    required this.menuBorder,
    required this.menuShadow,
    required this.controlHover,
    required this.softButtonHoverShadow,
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
  final Color primaryButtonHover;
  final Color dangerFill;
  final Color ice;
  final Color iceWeak;
  final Color scrim;
  final Color segment;
  final Color keyFill;
  final List<BoxShadow> keyShadow;
  final Color keyOkBorder;
  final List<BoxShadow> okShadow;
  final Color sheen;
  final Color neutralWeak;
  final Color stageBorder;
  final Color stageTrack;
  final Color stageWeak;
  final Color stageHint;
  final Color stageDashedRing;
  final double discTint;
  final double haloOpacity;
  final List<BoxShadow> primaryButtonShadow;
  final List<BoxShadow> primaryButtonHoverShadow;
  final List<BoxShadow> dangerButtonHoverShadow;
  final Color buttonHighlight;
  final Color buttonHighlightHover;
  final double headingWeight;
  final Color menuSurface;
  final Color menuBorder;
  final List<BoxShadow> menuShadow;
  final Color controlHover;
  final List<BoxShadow> softButtonHoverShadow;

  static const NbColors light = NbColors(
    primary: Color(0xFF6D4AFF),
    primaryHover: Color(0xFF5B3AEB),
    primaryWeak: Color(0xFFE0DBFF),
    primaryInk: Color(0xFF6336E1),
    onPrimary: Color(0xFFFFFFFF),
    hubTop: Color(0xFF7E5FFF),
    hubBottom: Color(0xFF622FF3),
    glow: Color.fromRGBO(109, 74, 255, 0.13),
    halo: Color.fromRGBO(109, 74, 255, 0.06),
    success: Color(0xFF008B68),
    successWeak: Color(0xFFB0F3D8),
    onSuccessDisc: Color(0xFFFFFFFF),
    netSurface: Color(0xFFD4F1E9),
    netDiscTop: Color(0xFF2BB18B),
    netDiscBottom: Color(0xFF007A5B),
    warning: Color(0xFF8C5700),
    warningRing: Color(0xFFD48300),
    warningWeak: Color(0xFFFFE0AE),
    danger: Color(0xFFB72649),
    dangerWeak: Color(0xFFFFD6DB),
    ground: Color(0xFFF3F1FB),
    card: Color(0xFFFEFDFF),
    surfaceWeak: Color(0xFFF1EFFA),
    track: Color(0xFFDDDAEB),
    nodeTop: Color(0xFFFEFEFF),
    nodeBottom: Color(0xFFEEEBFB),
    border: Color(0xFFD0CCE2),
    borderWeak: Color(0xFFE0DDED),
    text: Color(0xFF161420),
    textWeak: Color(0xFF5B586A),
    hint: Color(0xFF878493),
    tooltip: Color(0xFF0C0C14),
    successInk: Color(0xFF007455),
    primaryButton: Color(0xFF6D4AFF),
    cardShadow: [
      BoxShadow(color: Color.fromRGBO(35, 28, 56, 0.05), spreadRadius: 1),
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.06),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.07),
        offset: Offset(0, 6),
        blurRadius: 18,
      ),
    ],
    popoverShadow: [
      BoxShadow(color: Color.fromRGBO(35, 28, 56, 0.11), spreadRadius: 1),
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.06),
        offset: Offset(0, 2),
        blurRadius: 6,
      ),
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.18),
        offset: Offset(0, 18),
        blurRadius: 40,
      ),
    ],
    discShadow: [
      BoxShadow(
        color: Color.fromRGBO(0, 109, 76, 0.28),
        offset: Offset(0, 4),
        blurRadius: 10,
      ),
    ],
    nodeShadow: Color.fromRGBO(35, 28, 56, 0.16),
    primaryButtonHover: Color(0xFF7958FF),
    dangerFill: Color(0xFFB72649),
    ice: Color(0xFF4378AD),
    iceWeak: Color(0xFFE2F2FF),
    scrim: Color.fromRGBO(35, 28, 56, 0.32),
    segment: Color(0xFFE4E2F0),
    keyFill: Color(0xFFFEFDFF),
    keyShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.08),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
    ],
    keyOkBorder: Color.fromRGBO(0, 139, 104, 0.6),
    okShadow: [
      BoxShadow(
        color: Color.fromRGBO(0, 139, 104, 0.5),
        offset: Offset(0, 6),
        blurRadius: 14,
        spreadRadius: -6,
      ),
    ],
    sheen: Color.fromRGBO(255, 255, 255, 0.85),
    neutralWeak: Color(0xFFE3E1EF),
    stageBorder: Color(0xFFBBB7CF),
    stageTrack: Color(0xFFD6D3E7),
    stageWeak: Color(0xFFEAE7F6),
    stageHint: Color(0xFF817D91),
    stageDashedRing: Color.fromRGBO(129, 125, 145, 0.8),
    discTint: 0.1,
    haloOpacity: 0.12,
    primaryButtonShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.2),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.55),
        offset: Offset(0, 8),
        blurRadius: 18,
        spreadRadius: -8,
      ),
    ],
    primaryButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.18),
        offset: Offset(0, 2),
        blurRadius: 4,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.6),
        offset: Offset(0, 12),
        blurRadius: 24,
        spreadRadius: -10,
      ),
    ],
    dangerButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.18),
        offset: Offset(0, 2),
        blurRadius: 4,
      ),
      BoxShadow(
        color: Color.fromRGBO(192, 47, 80, 0.5),
        offset: Offset(0, 12),
        blurRadius: 24,
        spreadRadius: -10,
      ),
    ],
    buttonHighlight: Color.fromRGBO(255, 255, 255, 0.2),
    buttonHighlightHover: Color.fromRGBO(255, 255, 255, 0.24),
    headingWeight: 650,
    menuSurface: Color(0xFFFFFFFF),
    menuBorder: Color(0xFFDAD6EA),
    menuShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.08),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.18),
        offset: Offset(0, 10),
        blurRadius: 28,
        spreadRadius: -4,
      ),
    ],
    controlHover: Color.fromRGBO(35, 28, 56, 0.07),
    softButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(35, 28, 56, 0.16),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.55),
        offset: Offset(0, 6),
        blurRadius: 14,
        spreadRadius: -6,
      ),
    ],
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
    primaryButtonHover: Color(0xFF7958FF),
    dangerFill: Color(0xFFC9324B),
    ice: Color(0xFF8EC5FF),
    iceWeak: Color.fromRGBO(142, 197, 255, 0.16),
    scrim: Color.fromRGBO(0, 0, 0, 0.56),
    segment: Color(0xFF292633),
    keyFill: Color(0xFF292633),
    keyShadow: [],
    keyOkBorder: Color.fromRGBO(61, 214, 169, 0.45),
    okShadow: [],
    sheen: Color.fromRGBO(255, 255, 255, 0.22),
    neutralWeak: Color(0xFF292633),
    stageBorder: Color(0xFF3A3648),
    stageTrack: Color(0xFF33303F),
    stageWeak: Color(0xFF292633),
    stageHint: Color(0xFF8E8A9E),
    stageDashedRing: Color(0xFF3A3648),
    discTint: 0,
    haloOpacity: 0.13,
    primaryButtonShadow: [
      BoxShadow(
        color: Color.fromRGBO(40, 18, 140, 0.35),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.7),
        offset: Offset(0, 10),
        blurRadius: 22,
        spreadRadius: -8,
      ),
    ],
    primaryButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(40, 18, 140, 0.3),
        offset: Offset(0, 2),
        blurRadius: 4,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.8),
        offset: Offset(0, 16),
        blurRadius: 30,
        spreadRadius: -10,
      ),
    ],
    dangerButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(120, 10, 30, 0.3),
        offset: Offset(0, 2),
        blurRadius: 4,
      ),
      BoxShadow(
        color: Color.fromRGBO(194, 39, 63, 0.75),
        offset: Offset(0, 16),
        blurRadius: 30,
        spreadRadius: -10,
      ),
    ],
    buttonHighlight: Color.fromRGBO(255, 255, 255, 0.22),
    buttonHighlightHover: Color.fromRGBO(255, 255, 255, 0.26),
    headingWeight: 600,
    menuSurface: Color(0xFF322F3F),
    menuBorder: Color(0xFF45415A),
    menuShadow: [
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.4),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.6),
        offset: Offset(0, 12),
        blurRadius: 32,
        spreadRadius: -4,
      ),
    ],
    controlHover: Color.fromRGBO(255, 255, 255, 0.08),
    softButtonHoverShadow: [
      BoxShadow(
        color: Color.fromRGBO(40, 18, 140, 0.35),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color.fromRGBO(109, 74, 255, 0.75),
        offset: Offset(0, 8),
        blurRadius: 18,
        spreadRadius: -6,
      ),
    ],
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
    Color? primaryButtonHover,
    Color? dangerFill,
    Color? ice,
    Color? iceWeak,
    Color? scrim,
    Color? segment,
    Color? keyFill,
    List<BoxShadow>? keyShadow,
    Color? keyOkBorder,
    List<BoxShadow>? okShadow,
    Color? sheen,
    Color? neutralWeak,
    Color? stageBorder,
    Color? stageTrack,
    Color? stageWeak,
    Color? stageHint,
    Color? stageDashedRing,
    double? discTint,
    double? haloOpacity,
    List<BoxShadow>? primaryButtonShadow,
    List<BoxShadow>? primaryButtonHoverShadow,
    List<BoxShadow>? dangerButtonHoverShadow,
    Color? buttonHighlight,
    Color? buttonHighlightHover,
    double? headingWeight,
    Color? menuSurface,
    Color? menuBorder,
    List<BoxShadow>? menuShadow,
    Color? controlHover,
    List<BoxShadow>? softButtonHoverShadow,
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
      primaryButtonHover: primaryButtonHover ?? this.primaryButtonHover,
      dangerFill: dangerFill ?? this.dangerFill,
      ice: ice ?? this.ice,
      iceWeak: iceWeak ?? this.iceWeak,
      scrim: scrim ?? this.scrim,
      segment: segment ?? this.segment,
      keyFill: keyFill ?? this.keyFill,
      keyShadow: keyShadow ?? this.keyShadow,
      keyOkBorder: keyOkBorder ?? this.keyOkBorder,
      okShadow: okShadow ?? this.okShadow,
      sheen: sheen ?? this.sheen,
      neutralWeak: neutralWeak ?? this.neutralWeak,
      stageBorder: stageBorder ?? this.stageBorder,
      stageTrack: stageTrack ?? this.stageTrack,
      stageWeak: stageWeak ?? this.stageWeak,
      stageHint: stageHint ?? this.stageHint,
      stageDashedRing: stageDashedRing ?? this.stageDashedRing,
      discTint: discTint ?? this.discTint,
      haloOpacity: haloOpacity ?? this.haloOpacity,
      primaryButtonShadow: primaryButtonShadow ?? this.primaryButtonShadow,
      primaryButtonHoverShadow:
          primaryButtonHoverShadow ?? this.primaryButtonHoverShadow,
      dangerButtonHoverShadow:
          dangerButtonHoverShadow ?? this.dangerButtonHoverShadow,
      buttonHighlight: buttonHighlight ?? this.buttonHighlight,
      buttonHighlightHover: buttonHighlightHover ?? this.buttonHighlightHover,
      headingWeight: headingWeight ?? this.headingWeight,
      menuSurface: menuSurface ?? this.menuSurface,
      menuBorder: menuBorder ?? this.menuBorder,
      menuShadow: menuShadow ?? this.menuShadow,
      controlHover: controlHover ?? this.controlHover,
      softButtonHoverShadow:
          softButtonHoverShadow ?? this.softButtonHoverShadow,
    );
  }

  @override
  NbColors lerp(ThemeExtension<NbColors>? other, double t) {
    if (other is! NbColors) return this;
    return t < 0.5 ? this : other;
  }
}
