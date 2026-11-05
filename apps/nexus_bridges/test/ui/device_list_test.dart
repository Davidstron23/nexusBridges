import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_bridges/src/l10n/app_strings.dart';
import 'package:nexus_bridges/src/ui/device_list.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_diagram.dart';
import 'package:nexus_bridges/src/ui/diagram/flow_painter.dart';
import 'package:nexus_bridges/src/ui/icons/device_disc.dart';
import 'package:nexus_bridges/src/ui/icons/glyphs.dart';
import 'package:nexus_bridges/src/ui/modal/modal_button.dart';
import 'package:nexus_bridges/src/ui/modal/modal_frame.dart';
import 'package:nexus_bridges/src/ui/soft_button.dart';
import 'package:nexus_bridges/src/ui/theme/components.dart';
import 'package:nexus_bridges/src/ui/theme/tokens.dart';
import 'package:nexus_bridges_core/nexus_bridges_core.dart';

import 'fake_app_controller.dart';
import 'pairing_fixtures.dart';

final String _mineFp = fingerprintOf('AAAA1111');
final String _foreignFp = fingerprintOf('BBBB2222');
final String _hiddenFp = fingerprintOf('CCCC3333');
final String _ignoredFp = fingerprintOf('DDDD4444');
final String _phoneFp = fingerprintOf('EEEE5555');
final String _mismatchFp = fingerprintOf('FFFF6666');
final String _hiddenMismatchFp = fingerprintOf('9999AAAA');
final String _reinstallFp = fingerprintOf('1234ABCD');

const String _mineName = 'PC principal';
const String _foreignName = 'Equipo de Luis';
const String _hiddenName = 'Portatil viejo';
const String _ignoredName = 'Vecino';
const String _phoneName = 'Movil';
const String _mismatchName = 'Torre';
const String _hiddenMismatchName = 'Torre vieja';
const String _reinstallName = 'Portatil';
const String _oldName = 'Portatil 9999';
const String _longName = 'Portatil del salon con un nombre largo X';

DeviceEntry get _mine =>
    entry(fingerprint: _mineFp, name: _mineName, paired: true, mine: true);
DeviceEntry get _foreign =>
    entry(fingerprint: _foreignFp, name: _foreignName, paired: true);
DeviceEntry get _hidden => entry(
  fingerprint: _hiddenFp,
  name: _hiddenName,
  visible: false,
  paired: true,
  mine: true,
);
DeviceEntry get _ignored =>
    entry(fingerprint: _ignoredFp, name: _ignoredName, ignored: true);
DeviceEntry get _phone =>
    entry(fingerprint: _phoneFp, name: _phoneName, type: DeviceType.mobile);
DeviceEntry get _mismatch => entry(
  fingerprint: _mismatchFp,
  name: _mismatchName,
  paired: true,
  mine: true,
  mismatch: true,
);
DeviceEntry get _hiddenMismatch => entry(
  fingerprint: _hiddenMismatchFp,
  name: _hiddenMismatchName,
  visible: false,
  paired: true,
  mismatch: true,
);
DeviceEntry get _reinstall => entry(
  fingerprint: _reinstallFp,
  name: _reinstallName,
  possiblyReplaces: _oldName,
);

OutgoingTransferView _outgoing(String fingerprint) => OutgoingTransferView(
  peerFingerprint: fingerprint,
  peerName: 'peer',
  fileName: 'report.pdf',
  size: 1000,
  isProgram: false,
  phase: OutgoingPhase.uploading,
  sentBytes: 100,
  cancelling: false,
);

IncomingTransferView _incoming(String fingerprint, IncomingStage stage) =>
    IncomingTransferView(
      sessionId: 's1',
      peerFingerprint: fingerprint,
      peerName: 'peer',
      fileName: 'photo.jpg',
      size: 1000,
      isProgram: false,
      stage: stage,
    );

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<FakeAppController> _pumpList(
  WidgetTester tester,
  String code,
  List<DeviceEntry> entries, {
  Size size = const Size(800, 3000),
  OutgoingTransferView? outgoing,
  IncomingTransferView? incoming,
  bool reduceMotion = false,
}) async {
  _window(tester, size);
  final controller = FakeAppController(
    state: NodeState(entries: entries, outgoing: outgoing, incoming: incoming),
  );
  final busy = outgoing != null || incoming != null;
  await pumpHome(
    tester,
    controller,
    code,
    settle: !busy,
    reduceMotion: reduceMotion,
  );
  if (busy) {
    await tester.tap(find.text(stringsFor(code).devicesTab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }
  return controller;
}

Finder _row(String fingerprint) => find.byKey(ValueKey(fingerprint));

Finder _inRow(String fingerprint, Finder matching) =>
    find.descendant(of: _row(fingerprint), matching: matching);

DeviceRow _rowWidget(WidgetTester tester, String fingerprint) =>
    tester.widget<DeviceRow>(_row(fingerprint));

DeviceDisc _disc(WidgetTester tester, String fingerprint) =>
    tester.widget<DeviceDisc>(_inRow(fingerprint, find.byType(DeviceDisc)));

StatusChip _chip(WidgetTester tester, String fingerprint) =>
    tester.widget<StatusChip>(_inRow(fingerprint, find.byType(StatusChip)));

Color? _dotColor(WidgetTester tester, String fingerprint) {
  final dot = tester.widget<Container>(
    _inRow(
      fingerprint,
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    ),
  );
  expect(dot.constraints?.maxWidth, 6);
  expect(dot.constraints?.maxHeight, 6);
  return (dot.decoration! as BoxDecoration).color;
}

Finder _sendFinder(AppStrings strings, String fingerprint) => find.ancestor(
  of: _inRow(fingerprint, find.text(strings.sendEllipsis)),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
);

Color? _textColor(WidgetTester tester, Finder finder) =>
    tester.widget<Text>(finder).style?.color;

FlowPainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(FlowDiagram),
        matching: find.byType(CustomPaint),
      ),
    )
    .map((paint) => paint.foregroundPainter)
    .whereType<FlowPainter>()
    .single;

Finder _hoverFill(String fingerprint, Color color) => _inRow(
  fingerprint,
  find.byWidgetPredicate(
    (widget) => widget is ColoredBox && widget.color == color,
  ),
);

final class _RowCase {
  const _RowCase({
    required this.label,
    required this.entry,
    required this.glyph,
    required this.tone,
    required this.chip,
    required this.chipTone,
    required this.explanation,
    required this.canSend,
    required this.hasSend,
    required this.hasMenu,
  });

  final String label;
  final DeviceEntry entry;
  final DeviceGlyph glyph;
  final DiscTone tone;
  final String Function(AppStrings) chip;
  final ChipTone chipTone;
  final String? Function(AppStrings) explanation;
  final bool canSend;
  final bool hasSend;
  final bool hasMenu;
}

final List<_RowCase> _rowCases = [
  _RowCase(
    label: 'paired, mine and visible',
    entry: _mine,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.idle,
    chip: (s) => s.chipMine,
    chipTone: ChipTone.run,
    explanation: (_) => null,
    canSend: true,
    hasSend: true,
    hasMenu: true,
  ),
  _RowCase(
    label: 'paired, foreign and visible',
    entry: _foreign,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.idle,
    chip: (s) => s.chipForeign,
    chipTone: ChipTone.foreign,
    explanation: (_) => null,
    canSend: true,
    hasSend: true,
    hasMenu: true,
  ),
  _RowCase(
    label: 'paired and not visible',
    entry: _hidden,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.notVisible,
    chip: (s) => s.chipMine,
    chipTone: ChipTone.run,
    explanation: (s) => s.sendNeedsVisible,
    canSend: false,
    hasSend: true,
    hasMenu: true,
  ),
  _RowCase(
    label: 'paired with a mismatch and visible',
    entry: _mismatch,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.idle,
    chip: (s) => s.chipMine,
    chipTone: ChipTone.run,
    explanation: (s) => s.sendNeedsPairAgain,
    canSend: false,
    hasSend: true,
    hasMenu: true,
  ),
  _RowCase(
    label: 'paired with a mismatch and not visible',
    entry: _hiddenMismatch,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.notVisible,
    chip: (s) => s.chipForeign,
    chipTone: ChipTone.foreign,
    explanation: (s) => s.sendNeedsPairAgain,
    canSend: false,
    hasSend: true,
    hasMenu: true,
  ),
  _RowCase(
    label: 'ignored',
    entry: _ignored,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.idle,
    chip: (s) => s.ignoredLabel,
    chipTone: ChipTone.wait,
    explanation: (_) => null,
    canSend: false,
    hasSend: false,
    hasMenu: false,
  ),
  _RowCase(
    label: 'an unpaired phone',
    entry: _phone,
    glyph: DeviceGlyph.phone,
    tone: DiscTone.idle,
    chip: (s) => s.notPairedLabel,
    chipTone: ChipTone.wait,
    explanation: (_) => null,
    canSend: false,
    hasSend: false,
    hasMenu: false,
  ),
  _RowCase(
    label: 'a possible reinstall',
    entry: _reinstall,
    glyph: DeviceGlyph.pc,
    tone: DiscTone.idle,
    chip: (s) => s.notPairedLabel,
    chipTone: ChipTone.wait,
    explanation: (_) => null,
    canSend: false,
    hasSend: false,
    hasMenu: false,
  ),
];

void main() {
  group('E267 discToneFor', () {
    final visible = entry(fingerprint: _mineFp, name: _mineName, paired: true);
    final hidden = entry(
      fingerprint: _mineFp,
      name: _mineName,
      paired: true,
      visible: false,
    );

    test('a visible device with nothing going on is idle', () {
      expect(
        discToneFor(NodeState(entries: [visible]), visible),
        DiscTone.idle,
      );
    });

    test('a device out of sight is notVisible', () {
      expect(
        discToneFor(NodeState(entries: [hidden]), hidden),
        DiscTone.notVisible,
      );
    });

    test('an outgoing send to the device is sending, even out of sight', () {
      expect(
        discToneFor(
          NodeState(entries: [visible], outgoing: _outgoing(_mineFp)),
          visible,
        ),
        DiscTone.sending,
      );
      expect(
        discToneFor(
          NodeState(entries: [hidden], outgoing: _outgoing(_mineFp)),
          hidden,
        ),
        DiscTone.sending,
      );
    });

    test('an outgoing send to another device leaves it as it is', () {
      final state = NodeState(
        entries: [visible],
        outgoing: _outgoing(_foreignFp),
      );
      expect(discToneFor(state, visible), DiscTone.idle);
      expect(discToneFor(state, hidden), DiscTone.notVisible);
    });

    for (final stage in IncomingStage.values) {
      final asks =
          stage == IncomingStage.warning ||
          stage == IncomingStage.folderQuestion;
      test('an incoming in ${stage.name} from the device is '
          '${asks ? 'asking' : 'not asking'}', () {
        expect(
          discToneFor(
            NodeState(entries: [visible], incoming: _incoming(_mineFp, stage)),
            visible,
          ),
          asks ? DiscTone.asking : DiscTone.idle,
        );
        expect(
          discToneFor(
            NodeState(entries: [hidden], incoming: _incoming(_mineFp, stage)),
            hidden,
          ),
          asks ? DiscTone.asking : DiscTone.notVisible,
        );
      });
    }

    test('the question wins over the send to the same device', () {
      for (final stage in [
        IncomingStage.warning,
        IncomingStage.folderQuestion,
      ]) {
        expect(
          discToneFor(
            NodeState(
              entries: [visible],
              outgoing: _outgoing(_mineFp),
              incoming: _incoming(_mineFp, stage),
            ),
            visible,
          ),
          DiscTone.asking,
          reason: stage.name,
        );
      }
      expect(
        discToneFor(
          NodeState(
            entries: [visible],
            outgoing: _outgoing(_mineFp),
            incoming: _incoming(_mineFp, IncomingStage.receiving),
          ),
          visible,
        ),
        DiscTone.sending,
      );
    });

    test('a question from another device leaves it as it is', () {
      expect(
        discToneFor(
          NodeState(
            entries: [visible],
            incoming: _incoming(_foreignFp, IncomingStage.warning),
          ),
          visible,
        ),
        DiscTone.idle,
      );
    });

    test('the diagram popover uses this same public function', () {
      final source = File(
        'lib${Platform.pathSeparator}src${Platform.pathSeparator}ui'
        '${Platform.pathSeparator}diagram${Platform.pathSeparator}'
        'flow_diagram.dart',
      ).readAsStringSync();
      expect(source, contains('discToneFor('));
      expect(source, isNot(contains('_discToneFor')));
    });
  });

  for (final code in languageCodes) {
    final strings = stringsFor(code);
    final colors = NbColors.light;

    group('[$code] E267 every row type (RF-130, RF-49 of the 002)', () {
      for (final row in _rowCases) {
        testWidgets('${row.label}: disc, chip, dot, visibility, explanation, '
            'Send file and menu', (tester) async {
          await _pumpList(tester, code, [row.entry]);
          final fp = row.entry.fingerprint;

          expect(tester.takeException(), isNull);
          expect(_row(fp), findsOneWidget);
          expect(_rowWidget(tester, fp).entry.fingerprint, fp);
          expect(_inRow(fp, find.text(row.entry.displayName)), findsOneWidget);

          final disc = _disc(tester, fp);
          expect(disc.glyph, row.glyph);
          expect(disc.tone, row.tone);
          expect(_rowWidget(tester, fp).tone, row.tone);

          final chip = _chip(tester, fp);
          expect(chip.label, row.chip(strings));
          expect(chip.tone, row.chipTone);
          expect(chip.height, 20);

          final visibility = row.entry.visible
              ? strings.visibleLabel
              : strings.notVisibleLabel;
          final other = row.entry.visible
              ? strings.notVisibleLabel
              : strings.visibleLabel;
          expect(_inRow(fp, find.text(visibility)), findsOneWidget);
          expect(_inRow(fp, find.text(other)), findsNothing);
          expect(
            _textColor(tester, _inRow(fp, find.text(visibility))),
            colors.textWeak,
          );
          expect(
            _dotColor(tester, fp),
            row.entry.visible ? colors.successInk : colors.hint,
          );

          final explanation = row.explanation(strings);
          for (final text in [
            strings.sendNeedsVisible,
            strings.sendNeedsPairAgain,
          ]) {
            expect(
              _inRow(fp, find.text(text)),
              text == explanation ? findsOneWidget : findsNothing,
              reason: text,
            );
          }
          if (explanation != null) {
            expect(
              _textColor(tester, _inRow(fp, find.text(explanation))),
              colors.textWeak,
            );
          }

          final send = _sendFinder(strings, fp);
          expect(send, row.hasSend ? findsOneWidget : findsNothing);
          if (row.hasSend) {
            final button = tester.widget<ButtonStyleButton>(send);
            expect(
              find.ancestor(of: send, matching: find.byType(SoftButton)),
              findsOneWidget,
            );
            expect(button.onPressed != null, row.canSend);
            expect(row.entry.canSendFile, row.canSend);
            expect(
              find.descendant(
                of: send,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is GlyphIcon && widget.glyph == Glyphs.send,
                ),
              ),
              findsOneWidget,
            );
          }

          expect(
            _inRow(fp, find.byTooltip(strings.moreOptions)),
            row.hasMenu ? findsOneWidget : findsNothing,
          );
          if (row.hasMenu) {
            expect(
              _inRow(
                fp,
                find.byWidgetPredicate(
                  (widget) =>
                      widget is GlyphIcon && widget.glyph == Glyphs.more,
                ),
              ),
              findsOneWidget,
            );
          }
          expect(find.byType(Icon), findsNothing);
        });
      }

      testWidgets('an unpaired row offers Pair with the link glyph and an '
          'ignored one Stop ignoring', (tester) async {
        final controller = await _pumpList(tester, code, [_phone, _ignored]);

        final pair = find.ancestor(
          of: _inRow(_phoneFp, find.text(strings.pairButton)),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        );
        expect(pair, findsOneWidget);
        expect(tester.widget(pair), isA<OutlinedButton>());
        expect(
          find.descendant(
            of: pair,
            matching: find.byWidgetPredicate(
              (widget) => widget is GlyphIcon && widget.glyph == Glyphs.link,
            ),
          ),
          findsOneWidget,
        );
        expect(_inRow(_ignoredFp, find.text(strings.pairButton)), findsNothing);
        expect(
          _inRow(_ignoredFp, find.text(strings.unignoreButton)),
          findsOneWidget,
        );

        await tester.tap(pair);
        await tester.pumpAndSettle();
        await tester.tap(_inRow(_ignoredFp, find.text(strings.unignoreButton)));
        await tester.pumpAndSettle();
        expect(controller.calls, ['pair $_phoneFp', 'unignore $_ignoredFp']);
      });

      testWidgets('the menu of a paired row offers Unpair, which asks first '
          'and then unpairs', (tester) async {
        final controller = await _pumpList(tester, code, [
          _foreign,
        ], reduceMotion: true);

        await tester.tap(
          _inRow(_foreignFp, find.byTooltip(strings.moreOptions)),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.markAsMine), findsOneWidget);
        expect(find.text(strings.unpairButton), findsOneWidget);

        await tester.tap(find.text(strings.unpairButton));
        await tester.pumpAndSettle();
        expect(find.text(strings.unpairTitle(_foreignName)), findsOneWidget);
        expect(find.byType(NbModal), findsOneWidget);
        expect(controller.calls, isEmpty);
        await tester.tap(
          find.descendant(
            of: find.byType(NbModal),
            matching: find.widgetWithText(ModalButton, strings.unpairButton),
          ),
        );
        expect(controller.calls, ['unpair $_foreignFp']);
        await tester.pumpAndSettle();
        expect(find.byType(NbModal), findsNothing);
        expect(controller.calls, ['unpair $_foreignFp']);
      });

      testWidgets('a mismatch shows its warning and a possible reinstall its '
          'own, in text color', (tester) async {
        await _pumpList(tester, code, [_mismatch, _reinstall]);

        final warning = _inRow(_mismatchFp, find.text(strings.mismatchWarning));
        expect(warning, findsOneWidget);
        expect(_textColor(tester, warning), colors.text);
        final reinstall = _inRow(
          _reinstallFp,
          find.text(strings.possibleReinstall(_oldName)),
        );
        expect(reinstall, findsOneWidget);
        expect(_textColor(tester, reinstall), colors.text);
        expect(
          _inRow(_mismatchFp, find.text(strings.removeButton)),
          findsOneWidget,
        );
        expect(
          _inRow(_mismatchFp, find.text(strings.pairAgainButton)),
          findsOneWidget,
        );
      });

      testWidgets('a disc takes the tone of what is going on with its device, '
          'the question winning over the send', (tester) async {
        await _pumpList(
          tester,
          code,
          [_mine, _foreign, _hidden],
          outgoing: _outgoing(_mineFp),
          incoming: _incoming(_foreignFp, IncomingStage.warning),
        );

        expect(_disc(tester, _mineFp).tone, DiscTone.sending);
        expect(_disc(tester, _foreignFp).tone, DiscTone.asking);
        expect(_disc(tester, _hiddenFp).tone, DiscTone.notVisible);
        await tester.pumpWidget(const SizedBox());

        await _pumpList(
          tester,
          code,
          [_mine],
          outgoing: _outgoing(_mineFp),
          incoming: _incoming(_mineFp, IncomingStage.folderQuestion),
        );
        expect(_disc(tester, _mineFp).tone, DiscTone.asking);
        await tester.pumpWidget(const SizedBox());
      }, timeout: const Timeout(Duration(seconds: 30)));
    });

    group('[$code] E136 Send file only when the device can receive it '
        '(RF-130, RF-131, RF-210)', () {
      testWidgets(
        'visible and paired: Send is active and its menu calls sendFiles or '
        'sendFolders',
        (tester) async {
          final controller = await _pumpList(tester, code, [_foreign]);

          expect(
            tester
                .widget<ButtonStyleButton>(_sendFinder(strings, _foreignFp))
                .onPressed,
            isNotNull,
          );
          expect(find.text(strings.sendNeedsVisible), findsNothing);
          expect(find.text(strings.sendNeedsPairAgain), findsNothing);

          await tester.tap(_sendFinder(strings, _foreignFp));
          await tester.pumpAndSettle();
          expect(controller.calls, isEmpty);
          await tester.tap(find.text(strings.sendFilesOption));
          await tester.pumpAndSettle();
          expect(controller.calls, ['sendFiles $_foreignFp']);

          await tester.tap(_sendFinder(strings, _foreignFp));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.sendFoldersOption));
          await tester.pumpAndSettle();
          expect(controller.calls, [
            'sendFiles $_foreignFp',
            'sendFolders $_foreignFp',
          ]);
        },
      );

      final disabled = <String, (DeviceEntry, String Function(AppStrings))>{
        'not visible': (_hidden, (s) => s.sendNeedsVisible),
        'a mismatch while visible': (_mismatch, (s) => s.sendNeedsPairAgain),
        'a mismatch out of sight': (
          _hiddenMismatch,
          (s) => s.sendNeedsPairAgain,
        ),
      };
      for (final MapEntry(key: name, value: (row, reason))
          in disabled.entries) {
        testWidgets('$name: Send file is disabled and the reason is in '
            'textWeak', (tester) async {
          final controller = await _pumpList(tester, code, [row]);
          final fp = row.fingerprint;

          final send = _sendFinder(strings, fp);
          expect(tester.widget<ButtonStyleButton>(send).onPressed, isNull);
          final text = _inRow(fp, find.text(reason(strings)));
          expect(text, findsOneWidget);
          expect(_textColor(tester, text), colors.textWeak);
          expect(
            tester.getTopLeft(text).dy,
            greaterThan(tester.getBottomLeft(_chipFinder(fp)).dy),
          );
          expect(
            tester.getTopLeft(text).dy,
            lessThan(tester.getTopLeft(send).dy),
          );

          await tester.tap(send, warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(controller.calls, isEmpty);
        });
      }

      testWidgets('a row that comes into sight enables Send file and drops '
          'the reason', (tester) async {
        final controller = await _pumpList(tester, code, [_hidden]);
        expect(
          tester
              .widget<ButtonStyleButton>(_sendFinder(strings, _hiddenFp))
              .onPressed,
          isNull,
        );

        controller.emit(
          NodeState(
            entries: [
              entry(
                fingerprint: _hiddenFp,
                name: _hiddenName,
                paired: true,
                mine: true,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ButtonStyleButton>(_sendFinder(strings, _hiddenFp))
              .onPressed,
          isNotNull,
        );
        expect(find.text(strings.sendNeedsVisible), findsNothing);
      });
    });

    group('[$code] E267 the list', () {
      testWidgets('paired rows go first, in their order, in one card with '
          'Unpaired heading the unpaired and ignored ones', (tester) async {
        await _pumpList(tester, code, [
          _phone,
          _foreign,
          _ignored,
          _mine,
          _reinstall,
        ]);

        double top(Finder finder) => tester.getTopLeft(finder).dy;
        final heading = find.text(strings.sectionUnpaired);
        expect(heading, findsOneWidget);
        expect(_textColor(tester, heading), colors.textWeak);
        final order = [
          top(_row(_foreignFp)),
          top(_row(_mineFp)),
          top(heading),
          top(_row(_phoneFp)),
          top(_row(_ignoredFp)),
          top(_row(_reinstallFp)),
        ];
        for (var i = 1; i < order.length; i++) {
          expect(order[i], greaterThan(order[i - 1]), reason: 'item $i');
        }

        final card = find
            .ancestor(of: _row(_foreignFp), matching: find.byType(NbCard))
            .first;
        expect(tester.widget<NbCard>(card).padding, EdgeInsets.zero);
        expect(
          find.descendant(of: card, matching: find.byType(DeviceRow)),
          findsNWidgets(5),
        );
        expect(find.descendant(of: card, matching: heading), findsOneWidget);
      });

      testWidgets('without unpaired devices there is no Unpaired heading', (
        tester,
      ) async {
        await _pumpList(tester, code, [_mine, _foreign, _hidden]);

        expect(find.text(strings.sectionUnpaired), findsNothing);
        expect(find.byType(DeviceRow), findsNWidgets(3));
      });

      for (final MapEntry(key: name, value: only) in {
        'only unpaired devices': _phone,
        'only an ignored device': _ignored,
      }.entries) {
        testWidgets('with $name the Unpaired heading is there', (tester) async {
          await _pumpList(tester, code, [only]);

          expect(find.text(strings.sectionUnpaired), findsOneWidget);
          expect(
            tester.getTopLeft(find.text(strings.sectionUnpaired)).dy,
            lessThan(tester.getTopLeft(_row(only.fingerprint)).dy),
          );
        });
      }

      testWidgets('without devices the empty state is there and no card', (
        tester,
      ) async {
        await _pumpList(tester, code, const []);

        expect(find.text(strings.noDevicesYet), findsOneWidget);
        expect(find.byType(DeviceRow), findsNothing);
        expect(find.text(strings.sectionUnpaired), findsNothing);
      });
    });

    group('[$code] E268 hover between the list and the diagram', () {
      testWidgets('the mouse over a row puts its fingerprint in hovered, the '
          'row turns surfaceWeak and the diagram highlights it', (
        tester,
      ) async {
        await _pumpList(tester, code, [
          _mine,
          _foreign,
        ], size: const Size(800, 600));
        final hovered = _rowWidget(tester, _mineFp).hovered;
        expect(
          identical(_rowWidget(tester, _foreignFp).hovered, hovered),
          isTrue,
        );
        expect(
          identical(
            tester.widget<FlowDiagram>(find.byType(FlowDiagram)).hovered,
            hovered,
          ),
          isTrue,
        );

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(1, 599));
        await tester.pump();
        expect(hovered.value, isNull);
        expect(_hoverFill(_mineFp, colors.surfaceWeak), findsNothing);

        await mouse.moveTo(tester.getCenter(_row(_mineFp)));
        await tester.pump();
        expect(hovered.value, _mineFp);
        await tester.pump(rowHoverFade);
        expect(_hoverFill(_mineFp, colors.surfaceWeak), findsOneWidget);
        expect(_hoverFill(_foreignFp, colors.surfaceWeak), findsNothing);
        expect(_painter(tester).scene.hovered, _mineFp);

        await mouse.moveTo(tester.getCenter(_row(_foreignFp)));
        await tester.pump();
        expect(hovered.value, _foreignFp);
        await tester.pump(rowHoverFade);
        expect(_hoverFill(_mineFp, colors.surfaceWeak), findsNothing);
        expect(_hoverFill(_foreignFp, colors.surfaceWeak), findsOneWidget);

        await mouse.moveTo(const Offset(1, 599));
        await tester.pump();
        expect(hovered.value, isNull);
        await tester.pump(rowHoverFade);
        expect(_hoverFill(_foreignFp, colors.surfaceWeak), findsNothing);
        await tester.pump();
        expect(_painter(tester).scene.hovered, isNull);
      });

      testWidgets('the mouse over a device of the diagram highlights its row', (
        tester,
      ) async {
        await _pumpList(tester, code, [
          _mine,
          _foreign,
        ], size: const Size(800, 600));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(1, 599));
        await tester.pump();
        await mouse.moveTo(
          tester.getCenter(find.byKey(ValueKey('flow-peer-$_foreignFp'))),
        );
        await tester.pump();

        expect(_rowWidget(tester, _foreignFp).hovered.value, _foreignFp);
        await tester.pump(rowHoverFade);
        expect(_hoverFill(_foreignFp, colors.surfaceWeak), findsOneWidget);
        expect(_hoverFill(_mineFp, colors.surfaceWeak), findsNothing);
        await mouse.moveTo(const Offset(1, 599));
        await tester.pump(const Duration(milliseconds: 250));
      });
    });

    group('[$code] E267 point 137: the row fits the column of 280 px', () {
      testWidgets('a foreign device out of sight with a long name paints '
          'its chip and visibility without overflowing', (tester) async {
        final row = entry(
          fingerprint: _foreignFp,
          name: _longName,
          paired: true,
          visible: false,
        );
        await _pumpList(tester, code, [row], size: const Size(800, 600));

        expect(tester.takeException(), isNull);
        final rowRect = tester.getRect(_row(_foreignFp));
        expect(rowRect.width, closeTo(280, 0.01));

        final chip = _inRow(_foreignFp, find.byType(StatusChip));
        expect(tester.widget<StatusChip>(chip).label, strings.chipForeign);
        final chipText = _inRow(_foreignFp, find.text(strings.chipForeign));
        final visibility = _inRow(
          _foreignFp,
          find.text(strings.notVisibleLabel),
        );
        expect(chipText, findsOneWidget);
        expect(visibility, findsOneWidget);
        for (final finder in [chip, chipText, visibility]) {
          expect(
            tester.getRect(finder).right,
            lessThanOrEqualTo(rowRect.right),
          );
        }
        expect(
          find.ancestor(of: visibility, matching: find.byType(Flexible)),
          findsWidgets,
        );
        for (final finder in [chipText, visibility]) {
          final text = tester.widget<Text>(finder);
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
        }
        expect(
          tester.getRect(_sendFinder(strings, _foreignFp)).right,
          lessThanOrEqualTo(rowRect.right),
        );
        expect(
          _inRow(_foreignFp, find.text(strings.sendNeedsVisible)),
          findsOneWidget,
        );
      });

      testWidgets('every row type together fits the column of 280 px', (
        tester,
      ) async {
        await _pumpList(tester, code, [
          for (final row in _rowCases) row.entry,
        ], size: const Size(800, 600));

        expect(tester.takeException(), isNull);
        for (final row in _rowCases) {
          final rect = tester.getRect(_row(row.entry.fingerprint));
          expect(rect.width, closeTo(280, 0.01), reason: row.label);
        }
      });
    });
  }
}

Finder _chipFinder(String fingerprint) =>
    _inRow(fingerprint, find.byType(StatusChip));
