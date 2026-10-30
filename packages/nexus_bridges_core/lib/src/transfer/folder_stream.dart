import 'dart:typed_data';

import 'manifest.dart' show FolderManifest;

const int frameHeaderBytes = 12;
const int frameTrailerBytes = 1;

Uint8List encodeFrameHeader(int index, int length) {
  final header = ByteData(frameHeaderBytes)
    ..setUint32(0, index)
    ..setInt64(4, length);
  return header.buffer.asUint8List();
}

enum FrameFault { unexpectedIndex, tooManyBytes, shortLength, badTrailer }

enum _FrameState { header, data, trailer, complete, failed }

final class FrameParser {
  FrameParser({
    required this._manifest,
    required this._onStart,
    required this._onData,
    required this._onEnd,
  }) {
    if (_manifest.files == 0) _state = _FrameState.complete;
  }

  final FolderManifest _manifest;
  final void Function(int index, int length) _onStart;
  final void Function(Uint8List bytes) _onData;
  final void Function(int index) _onEnd;
  final Uint8List _header = Uint8List(frameHeaderBytes);
  _FrameState _state = _FrameState.header;
  int _headerFill = 0;
  int _next = 0;
  int _current = 0;
  int _remaining = 0;

  bool get complete => _state == _FrameState.complete;

  int get filesDone => _next;

  FrameFault? add(Uint8List chunk) {
    var position = 0;
    while (position < chunk.length) {
      switch (_state) {
        case _FrameState.failed:
          return null;
        case _FrameState.complete:
          return _fail(FrameFault.unexpectedIndex);
        case _FrameState.header:
          final take = _min(
            frameHeaderBytes - _headerFill,
            chunk.length - position,
          );
          _header.setRange(_headerFill, _headerFill + take, chunk, position);
          _headerFill += take;
          position += take;
          if (_headerFill < frameHeaderBytes) break;
          final fault = _startFrame();
          if (fault != null) return fault;
        case _FrameState.data:
          final take = _min(_remaining, chunk.length - position);
          if (take > 0) {
            _onData(Uint8List.sublistView(chunk, position, position + take));
          }
          _remaining -= take;
          position += take;
          if (_remaining == 0) _state = _FrameState.trailer;
        case _FrameState.trailer:
          final byte = chunk[position++];
          if (byte != 0) return _fail(FrameFault.badTrailer);
          _onEnd(_current);
          _next++;
          _state = _next == _manifest.files
              ? _FrameState.complete
              : _FrameState.header;
      }
    }
    return null;
  }

  FrameFault? _startFrame() {
    final data = ByteData.sublistView(_header);
    final index = data.getUint32(0);
    final length = data.getInt64(4);
    _headerFill = 0;
    if (_next >= _manifest.files || index != _manifest.fileIndexes[_next]) {
      return _fail(FrameFault.unexpectedIndex);
    }
    final expected = _manifest.sizeOf(index);
    if (length < 0 || length > expected) return _fail(FrameFault.tooManyBytes);
    if (length < expected) return _fail(FrameFault.shortLength);
    _current = index;
    _remaining = length;
    _onStart(index, length);
    _state = length == 0 ? _FrameState.trailer : _FrameState.data;
    return null;
  }

  FrameFault _fail(FrameFault fault) {
    _state = _FrameState.failed;
    return fault;
  }

  int _min(int a, int b) => a < b ? a : b;
}

final class FrameLayout {
  FrameLayout(FolderManifest manifest) {
    final count = manifest.files;
    _ends = Int64List(count);
    _payloadBefore = Int64List(count);
    _sizes = Int64List(count);
    var offset = 0;
    var payload = 0;
    for (var i = 0; i < count; i++) {
      final size = manifest.sizeOf(manifest.fileIndexes[i]);
      _sizes[i] = size;
      _payloadBefore[i] = payload;
      offset += frameHeaderBytes + size + frameTrailerBytes;
      payload += size;
      _ends[i] = offset;
    }
    totalBytes = offset;
  }

  late final Int64List _ends;
  late final Int64List _payloadBefore;
  late final Int64List _sizes;
  late final int totalBytes;

  ({int files, int payload}) progressAt(int rawSent) {
    final count = _ends.length;
    if (count == 0 || rawSent <= 0) return (files: 0, payload: 0);
    var low = 0;
    var high = count;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_ends[middle] <= rawSent) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low >= count) {
      return (
        files: count,
        payload: _payloadBefore[count - 1] + _sizes[count - 1],
      );
    }
    final start = low == 0 ? 0 : _ends[low - 1];
    final inFrame = rawSent - start - frameHeaderBytes;
    final partial = inFrame <= 0
        ? 0
        : (inFrame > _sizes[low] ? _sizes[low] : inFrame);
    return (files: low, payload: _payloadBefore[low] + partial);
  }
}
