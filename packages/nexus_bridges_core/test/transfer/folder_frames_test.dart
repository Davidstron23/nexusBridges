import 'dart:math';
import 'dart:typed_data';

import 'package:nexus_bridges_core/src/transfer/folder_stream.dart';
import 'package:nexus_bridges_core/src/transfer/manifest.dart';
import 'package:test/test.dart';

const int seed = 20261031;

FolderManifest manifestOf(List<int> sizes, {bool withFolders = true}) {
  final builder = ManifestBuilder();
  final folder = withFolders ? builder.addFolder(0, 'dir') : 0;
  if (withFolders) builder.addFolder(0, 'empty');
  for (var i = 0; i < sizes.length; i++) {
    final file = builder.addFile(i.isEven ? 0 : folder, 'f$i', sizes[i]);
    builder.setFile(file, sizes[i], Uint8List(32));
  }
  return builder.build();
}

Uint8List frame(int index, List<int> data, {int? length, int trailer = 0}) {
  final out = BytesBuilder()
    ..add(encodeFrameHeader(index, length ?? data.length))
    ..add(data)
    ..addByte(trailer);
  return out.toBytes();
}

Uint8List validStream(FolderManifest manifest) {
  final out = BytesBuilder();
  for (final index in manifest.fileIndexes) {
    out.add(
      frame(index, List.generate(manifest.sizeOf(index), (i) => i % 251)),
    );
  }
  return out.toBytes();
}

class Recorder {
  Recorder(FolderManifest manifest) {
    parser = FrameParser(
      manifest: manifest,
      onStart: (index, length) => events.add('start $index $length'),
      onData: (bytes) => data.addAll(bytes),
      onEnd: (index) => events.add('end $index'),
    );
  }

  late final FrameParser parser;
  final List<String> events = [];
  final List<int> data = [];
}

FrameFault? feed(Recorder recorder, Uint8List bytes, [List<int>? sizes]) {
  if (sizes == null) return recorder.parser.add(bytes);
  var position = 0;
  var turn = 0;
  while (position < bytes.length) {
    final size = sizes[turn++ % sizes.length];
    final end = min(bytes.length, position + size);
    final fault = recorder.parser.add(
      Uint8List.sublistView(bytes, position, end),
    );
    if (fault != null) return fault;
    position = end;
  }
  return null;
}

typedef Outcome = ({FrameFault? fault, bool complete, int done});

Outcome referenceOutcome(FolderManifest manifest, Uint8List stream) {
  var position = 0;
  var done = 0;
  final indexes = manifest.fileIndexes;
  while (done < indexes.length) {
    if (stream.length - position < frameHeaderBytes) {
      return (fault: null, complete: false, done: done);
    }
    final header = ByteData.sublistView(
      stream,
      position,
      position + frameHeaderBytes,
    );
    final index = header.getUint32(0);
    final length = header.getInt64(4);
    if (index != indexes[done]) {
      return (fault: FrameFault.unexpectedIndex, complete: false, done: done);
    }
    final expected = manifest.sizeOf(index);
    if (length < 0 || length > expected) {
      return (fault: FrameFault.tooManyBytes, complete: false, done: done);
    }
    if (length < expected) {
      return (fault: FrameFault.shortLength, complete: false, done: done);
    }
    position += frameHeaderBytes;
    if (stream.length - position < length + 1) {
      return (fault: null, complete: false, done: done);
    }
    position += length;
    if (stream[position] != 0) {
      return (fault: FrameFault.badTrailer, complete: false, done: done);
    }
    position++;
    done++;
  }
  if (position < stream.length) {
    return (fault: FrameFault.unexpectedIndex, complete: true, done: done);
  }
  return (fault: null, complete: true, done: done);
}

Outcome run(FolderManifest manifest, Uint8List stream, List<int>? sizes) {
  final recorder = Recorder(manifest);
  final fault = feed(recorder, stream, sizes);
  return (
    fault: fault,
    complete: recorder.parser.complete && fault == null,
    done: recorder.parser.filesDone,
  );
}

void main() {
  group('E438, RF-274 and RF-275: FrameParser', () {
    final manifest = manifestOf([5, 0, 7]);

    test('a valid stream completes and delivers every byte in order', () {
      final recorder = Recorder(manifest);

      expect(feed(recorder, validStream(manifest)), isNull);
      expect(recorder.parser.complete, isTrue);
      expect(recorder.parser.filesDone, 3);
      expect(recorder.events, [
        'start 3 5',
        'end 3',
        'start 4 0',
        'end 4',
        'start 5 7',
        'end 5',
      ]);
      expect(recorder.data, [
        ...List.generate(5, (i) => i % 251),
        ...List.generate(7, (i) => i % 251),
      ]);
    });

    test('the stream may be cut at any single byte, header included', () {
      final stream = validStream(manifest);
      for (var cut = 0; cut <= stream.length; cut++) {
        final recorder = Recorder(manifest);

        expect(
          recorder.parser.add(Uint8List.sublistView(stream, 0, cut)),
          isNull,
        );
        expect(
          recorder.parser.add(Uint8List.sublistView(stream, cut)),
          isNull,
          reason: 'cut at $cut',
        );
        expect(recorder.parser.complete, isTrue, reason: 'cut at $cut');
        expect(recorder.parser.filesDone, 3);
        expect(recorder.data.length, 12, reason: 'cut at $cut');
      }
    });

    test('one byte at a time completes the same way', () {
      final recorder = Recorder(manifest);

      expect(feed(recorder, validStream(manifest), [1]), isNull);
      expect(recorder.parser.complete, isTrue);
      expect(recorder.data.length, 12);
    });

    test('it is not complete until the last closing byte arrives', () {
      final stream = validStream(manifest);
      final recorder = Recorder(manifest);

      expect(
        recorder.parser.add(
          Uint8List.sublistView(stream, 0, stream.length - 1),
        ),
        isNull,
      );
      expect(recorder.parser.complete, isFalse);
      expect(recorder.parser.filesDone, 2);
      expect(recorder.parser.add(Uint8List.fromList([0])), isNull);
      expect(recorder.parser.complete, isTrue);
    });

    test('an index that skips ahead is refused', () {
      final stream = BytesBuilder()
        ..add(frame(3, List.filled(5, 1)))
        ..add(frame(5, const []));
      final recorder = Recorder(manifest);

      expect(feed(recorder, stream.toBytes()), FrameFault.unexpectedIndex);
      expect(recorder.parser.complete, isFalse);
    });

    test('a repeated index is refused', () {
      final stream = BytesBuilder()
        ..add(frame(3, List.filled(5, 1)))
        ..add(frame(3, List.filled(5, 1)));

      expect(
        feed(Recorder(manifest), stream.toBytes()),
        FrameFault.unexpectedIndex,
      );
    });

    test('an index that is a folder, zero or out of range is refused', () {
      for (final index in [1, 2, 0, 6, 99, 0xFFFFFFFF]) {
        expect(
          feed(Recorder(manifest), frame(index, List.filled(5, 1))),
          FrameFault.unexpectedIndex,
          reason: '$index',
        );
      }
    });

    test('a longer length than the manifest says is refused', () {
      expect(
        feed(Recorder(manifest), frame(3, List.filled(5, 1), length: 6)),
        FrameFault.tooManyBytes,
      );
      expect(
        feed(Recorder(manifest), frame(3, const [], length: 1 << 40)),
        FrameFault.tooManyBytes,
      );
    });

    test('a negative length is refused', () {
      expect(
        feed(Recorder(manifest), frame(3, const [], length: -1)),
        FrameFault.tooManyBytes,
      );
    });

    test('a shorter length than the manifest says is refused', () {
      expect(
        feed(Recorder(manifest), frame(3, List.filled(5, 1), length: 4)),
        FrameFault.shortLength,
      );
      expect(
        feed(Recorder(manifest), frame(3, const [], length: 0)),
        FrameFault.shortLength,
      );
    });

    test('a closing byte other than zero is refused', () {
      for (final trailer in [1, 0x7F, 0x80, 0xFF]) {
        final recorder = Recorder(manifest);

        expect(
          feed(recorder, frame(3, List.filled(5, 1), trailer: trailer)),
          FrameFault.badTrailer,
          reason: '$trailer',
        );
        expect(recorder.events, ['start 3 5']);
      }
    });

    test('a closing byte other than zero on an empty file is refused', () {
      final stream = BytesBuilder()
        ..add(frame(3, List.filled(5, 1)))
        ..add(frame(4, const [], trailer: 9));

      expect(feed(Recorder(manifest), stream.toBytes()), FrameFault.badTrailer);
    });

    test('after a fault the parser ignores everything else', () {
      final recorder = Recorder(manifest);

      expect(feed(recorder, frame(9, const [])), FrameFault.unexpectedIndex);
      final seen = recorder.events.length;
      expect(recorder.parser.add(validStream(manifest)), isNull);
      expect(recorder.events.length, seen);
      expect(recorder.data, isEmpty);
      expect(recorder.parser.complete, isFalse);
    });

    test('bytes after the last frame are a fault', () {
      final stream = BytesBuilder()
        ..add(validStream(manifest))
        ..addByte(0);
      final recorder = Recorder(manifest);

      expect(feed(recorder, stream.toBytes()), FrameFault.unexpectedIndex);
      expect(recorder.parser.filesDone, 3);
    });

    test('a manifest with no files is complete from the start', () {
      final empty = manifestOf(const []);
      final recorder = Recorder(empty);

      expect(recorder.parser.complete, isTrue);
      expect(recorder.parser.filesDone, 0);
      expect(
        recorder.parser.add(Uint8List.fromList([0])),
        FrameFault.unexpectedIndex,
      );
    });

    test('encodeFrameHeader writes the index and length big endian', () {
      expect(encodeFrameHeader(0x01020304, 0x0A0B0C0D0E0F1011), [
        1,
        2,
        3,
        4,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x0E,
        0x0F,
        0x10,
        0x11,
      ]);
      expect(encodeFrameHeader(7, 0).length, frameHeaderBytes);
    });

    test('random streams agree with an independent parser', () {
      final random = Random(seed);
      for (var i = 0; i < 10000; i++) {
        final sizes = [
          for (var n = random.nextInt(5); n > 0; n--) random.nextInt(40),
        ];
        final tree = manifestOf(sizes, withFolders: random.nextBool());
        final data = List<int>.of(validStream(tree));
        final rounds = i % 4 == 0 ? 0 : 1 + random.nextInt(3);
        for (var r = 0; r < rounds; r++) {
          if (data.isEmpty) {
            data.add(random.nextInt(256));
            continue;
          }
          switch (random.nextInt(5)) {
            case 0:
              data[random.nextInt(data.length)] = random.nextInt(256);
            case 1:
              data.removeAt(random.nextInt(data.length));
            case 2:
              data.insert(random.nextInt(data.length + 1), random.nextInt(256));
            case 3:
              data.length = random.nextInt(data.length + 1);
            case 4:
              data[random.nextInt(min(data.length, frameHeaderBytes))] ^=
                  1 << random.nextInt(8);
          }
        }
        final stream = Uint8List.fromList(data);
        final expected = referenceOutcome(tree, stream);
        final chunks = [for (var n = 0; n < 8; n++) 1 + random.nextInt(20)];

        final whole = run(tree, stream, null);
        final chunked = run(tree, stream, chunks);

        expect(whole.fault, expected.fault, reason: 'iteration $i whole');
        expect(chunked.fault, expected.fault, reason: 'iteration $i chunked');
        expect(
          whole.complete,
          expected.complete && expected.fault == null,
          reason: 'iteration $i complete',
        );
        expect(chunked.complete, whole.complete, reason: 'iteration $i');
        expect(chunked.done, whole.done, reason: 'iteration $i done');
        if (expected.fault == null) {
          expect(whole.done, expected.done, reason: 'iteration $i done');
        }
      }
    });
  });

  group('E438, RF-275: FrameLayout', () {
    final manifest = manifestOf([5, 0, 7]);
    final layout = FrameLayout(manifest);

    test('totalBytes is what the stream measures', () {
      expect(layout.totalBytes, 13 + 5 + 13 + 0 + 13 + 7);
      expect(layout.totalBytes, validStream(manifest).length);
      expect(layout.totalBytes, folderStreamLength(manifest));
    });

    test('progress at the edges of every frame', () {
      expect(layout.progressAt(0), (files: 0, payload: 0));
      expect(layout.progressAt(-5), (files: 0, payload: 0));
      expect(layout.progressAt(11), (files: 0, payload: 0));
      expect(layout.progressAt(12), (files: 0, payload: 0));
      expect(layout.progressAt(13), (files: 0, payload: 1));
      expect(layout.progressAt(16), (files: 0, payload: 4));
      expect(layout.progressAt(17), (files: 0, payload: 5));
      expect(layout.progressAt(18), (files: 1, payload: 5));
      expect(layout.progressAt(19), (files: 1, payload: 5));
      expect(layout.progressAt(30), (files: 1, payload: 5));
      expect(layout.progressAt(31), (files: 2, payload: 5));
      expect(layout.progressAt(32), (files: 2, payload: 5));
      expect(layout.progressAt(43), (files: 2, payload: 5));
      expect(layout.progressAt(44), (files: 2, payload: 6));
      expect(layout.progressAt(50), (files: 2, payload: 12));
      expect(layout.progressAt(51), (files: 3, payload: 12));
      expect(layout.progressAt(layout.totalBytes), (files: 3, payload: 12));
      expect(layout.progressAt(layout.totalBytes + 999), (
        files: 3,
        payload: 12,
      ));
    });

    test('it agrees with a linear count at every position', () {
      var lastFiles = 0;
      var lastPayload = 0;
      for (var sent = 0; sent <= layout.totalBytes; sent++) {
        var files = 0;
        var payload = 0;
        var offset = 0;
        for (final index in manifest.fileIndexes) {
          final size = manifest.sizeOf(index);
          final start = offset;
          final end = offset + frameHeaderBytes + size + frameTrailerBytes;
          if (sent >= end) {
            files++;
            payload += size;
          } else if (sent > start + frameHeaderBytes) {
            payload += min(size, sent - start - frameHeaderBytes);
          }
          offset = end;
        }
        final progress = layout.progressAt(sent);
        expect(progress, (files: files, payload: payload), reason: '$sent');
        expect(progress.files, greaterThanOrEqualTo(lastFiles));
        expect(progress.payload, greaterThanOrEqualTo(lastPayload));
        lastFiles = progress.files;
        lastPayload = progress.payload;
      }
    });

    test('a manifest with no files has no progress and no bytes', () {
      final empty = FrameLayout(manifestOf(const []));

      expect(empty.totalBytes, 0);
      expect(empty.progressAt(0), (files: 0, payload: 0));
      expect(empty.progressAt(100), (files: 0, payload: 0));
    });

    test('many files and large sizes stay exact', () {
      final sizes = [
        for (var i = 0; i < 2000; i++) i.isEven ? 0 : (1 << 33) + i,
      ];
      final big = manifestOf(sizes, withFolders: false);
      final bigLayout = FrameLayout(big);
      var offset = 0;
      var payload = 0;

      for (var n = 0; n < sizes.length; n++) {
        final size = sizes[n];
        expect(bigLayout.progressAt(offset + frameHeaderBytes + size), (
          files: n,
          payload: payload + size,
        ), reason: 'file $n at the end of its data');
        offset += frameHeaderBytes + size + frameTrailerBytes;
        payload += size;
        expect(bigLayout.progressAt(offset), (
          files: n + 1,
          payload: payload,
        ), reason: 'file $n closed');
      }
      expect(bigLayout.totalBytes, offset);
    });
  });
}
