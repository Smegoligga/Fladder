import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/screens/shared/fladder_notification_overlay.dart';
import 'package:fladder/screens/trim/trimmer_api.dart';

/// Opens the clip trimmer for [item]. Completes with true when that clip was deleted.
Future<bool?> showTrimScreen(BuildContext context, ItemBaseModel item) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(builder: (_) => TrimScreen(item: item)),
  );
}

class TrimScreen extends ConsumerStatefulWidget {
  final ItemBaseModel item;
  const TrimScreen({required this.item, super.key});

  @override
  ConsumerState<TrimScreen> createState() => _TrimScreenState();
}

enum _Grab { start, end, head }

class _TrimScreenState extends ConsumerState<TrimScreen> {
  static const double _minLen = 0.3;
  static const List<double> _speeds = [1, 0.5, 0.25, 2];

  TrimmerApi? _api;
  String? _path; // trimmer path of the clip on screen
  String? _firstPath; // the clip this screen was opened for
  String _title = '';
  VideoPlayerController? _vc;
  Timer? _poll;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String _msg = '';
  bool _msgErr = false;

  double _dur = 1;
  double _start = 0;
  double _end = 1;
  double _pos = 0;
  bool _dragging = false;
  bool _wasPlaying = false;
  bool _seeking = false;
  double? _pendingSeek;
  bool _jumping = false;
  bool _polling = false;
  int _speed = 0;

  bool _exact = false;
  bool _copy = false;
  bool _keep = false;
  bool _loop = true;
  bool _fullQuality = false;
  bool _usingLite = false;
  Map<String, dynamic>? _bk;
  bool _hasBackup = false;
  int _left = -1;
  final Set<String> _skipped = {};
  bool _firstDeleted = false;

  @override
  void initState() {
    super.initState();
    _title = widget.item.name;
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) => _onPoll());
    _init();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _vc?.removeListener(_onPlayerChanged);
    _vc?.dispose();
    super.dispose();
  }

  Duration _d(double s) => Duration(milliseconds: (s * 1000).round());

  String _fmt(double s) {
    if (s < 0) s = 0;
    final m = s ~/ 60;
    final r = s - m * 60;
    return '$m:${r.toStringAsFixed(2).padLeft(5, '0')}';
  }

  void _say(String t, {bool err = false}) {
    if (!mounted) return;
    setState(() {
      _msg = t;
      _msgErr = err;
    });
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = await TrimmerApi.of(ref);
      if (api == null) throw 'Not signed in';
      _api = api;
      final r = await api.get('/api/byid', query: {'id': widget.item.id});
      final p = r['p'];
      if (p is! String) throw (r['error'] ?? 'This clip is not in a folder the trimmer can edit');
      _firstPath = p;
      await _open(p);
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Loads a clip into the editor (the small data-saver copy when there is one, unless full quality is on).
  Future<void> _open(String path) async {
    final api = _api!;
    final info = await api.get('/api/info', query: {'p': path});
    final duration = info['duration'];
    if (duration is! num) throw (info['error'] ?? 'Could not read the clip');
    final lite = info['lite'] == true && !_fullQuality;
    final vc = VideoPlayerController.networkUrl(
      Uri.parse(api.videoUrl(path, lite: !_fullQuality, stamp: DateTime.now().millisecondsSinceEpoch)),
    );
    try {
      await vc.initialize();
      await vc.setLooping(false);
      await vc.setPlaybackSpeed(_speeds[_speed]);
    } catch (e) {
      await vc.dispose();
      rethrow;
    }
    if (!mounted) {
      await vc.dispose();
      return;
    }
    final old = _vc;
    old?.removeListener(_onPlayerChanged);
    vc.addListener(_onPlayerChanged);
    final bk = info['bk'];
    setState(() {
      _path = path;
      _dur = math.max(duration.toDouble(), _minLen);
      _start = 0;
      _end = _dur;
      _pos = 0;
      _dragging = false;
      _hasBackup = info['hasBackup'] == true;
      _bk = bk is Map<String, dynamic> ? bk : null;
      _keep = _bk?['keep'] == true;
      _usingLite = lite;
      _vc = vc;
    });
    await old?.dispose();
  }

  void _onPlayerChanged() {
    final vc = _vc;
    if (vc == null || !mounted) return;
    if (!vc.value.isPlaying && !_dragging && !_seeking) {
      _pos = vc.value.position.inMilliseconds / 1000.0;
    }
    setState(() {});
  }

  /// The player only reports its position twice a second, so ask it directly while it plays:
  /// that keeps the playhead smooth and lets playback turn round exactly at the end of the cut.
  Future<void> _onPoll() async {
    final vc = _vc;
    if (vc == null || _polling || !mounted || !vc.value.isPlaying || _dragging) return;
    _polling = true;
    try {
      final p = await vc.position;
      if (p == null || !mounted || vc != _vc || _dragging) return;
      final pos = p.inMilliseconds / 1000.0;
      if (!_jumping && pos >= _end - 0.03) {
        _jumping = true;
        try {
          if (_loop) {
            await vc.seekTo(_d(_start));
            _pos = _start;
          } else {
            await vc.pause();
            await vc.seekTo(_d(_end));
            _pos = _end;
          }
        } finally {
          _jumping = false;
        }
      } else if (!_jumping) {
        _pos = pos;
      }
      if (mounted) setState(() {});
    } catch (_) {
      // the player was replaced or closed while we asked
    } finally {
      _polling = false;
    }
  }

  /// Seeks without queueing up a seek per pixel: only the newest target is kept while one is running.
  Future<void> _seek(double s) async {
    s = s.clamp(0.0, _dur).toDouble();
    _pos = s;
    if (_seeking) {
      _pendingSeek = s;
      return;
    }
    _seeking = true;
    try {
      double? target = s;
      while (target != null) {
        _pendingSeek = null;
        await _vc?.seekTo(_d(target));
        target = _pendingSeek;
      }
    } catch (_) {
      // ignore: the clip was swapped mid-seek
    } finally {
      _seeking = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _togglePlay() async {
    final vc = _vc;
    if (vc == null) return;
    if (vc.value.isPlaying) {
      await vc.pause();
      return;
    }
    if (_pos < _start - 0.05 || _pos >= _end - 0.08) await _seek(_start);
    await vc.play();
  }

  Future<void> _playFromStart() async {
    await _seek(_start);
    await _vc?.play();
  }

  Future<void> _playEnding() async {
    await _seek(math.max(_start, _end - 2));
    await _vc?.play();
  }

  Future<void> _step(double by) async {
    await _vc?.pause();
    await _seek(_pos + by);
  }

  void _setStart(double v, {bool show = true}) {
    v = v.clamp(0.0, _dur).toDouble();
    if (v > _end - _minLen) {
      _say('The start has to be before the end.', err: true);
      return;
    }
    _vc?.pause();
    setState(() {
      _start = v;
      _msg = '';
    });
    if (show) _seek(v);
  }

  void _setEnd(double v, {bool show = true}) {
    v = v.clamp(0.0, _dur).toDouble();
    if (v < _start + _minLen) {
      _say('The end has to be after the start.', err: true);
      return;
    }
    _vc?.pause();
    setState(() {
      _end = v;
      _msg = '';
    });
    if (show) _seek(v);
  }

  void _onGrab(_Grab what) {
    _wasPlaying = _vc?.value.isPlaying ?? false;
    _dragging = true;
    _vc?.pause();
  }

  void _onMove(_Grab what, double s) {
    switch (what) {
      case _Grab.start:
        s = s.clamp(0.0, _end - _minLen).toDouble();
        setState(() => _start = s);
      case _Grab.end:
        s = s.clamp(_start + _minLen, _dur).toDouble();
        setState(() => _end = s);
      case _Grab.head:
        s = s.clamp(0.0, _dur).toDouble();
        setState(() {});
    }
    _seek(s);
  }

  void _onRelease(_Grab what) {
    _dragging = false;
    if (what == _Grab.head && _wasPlaying) _vc?.play();
    if (mounted) setState(() {});
  }

  Future<void> _cycleSpeed() async {
    setState(() => _speed = (_speed + 1) % _speeds.length);
    await _vc?.setPlaybackSpeed(_speeds[_speed]);
  }

  Future<void> _toggleQuality() async {
    final path = _path;
    if (path == null || _busy) return;
    setState(() {
      _fullQuality = !_fullQuality;
      _busy = true;
    });
    final keepStart = _start, keepEnd = _end, keepPos = _pos;
    try {
      await _open(path);
      if (mounted) {
        setState(() {
          _start = keepStart.clamp(0.0, _dur).toDouble();
          _end = keepEnd.clamp(_start, _dur).toDouble();
        });
        await _seek(keepPos);
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save() async {
    final api = _api, path = _path;
    if (_busy || api == null || path == null) return;
    if (_start <= 0.05 && _end >= _dur - 0.05) {
      _say('Nothing to cut: the start and end cover the whole clip.', err: true);
      return;
    }
    if (!_copy) {
      final ok = await _confirm(
        'Replace the clip?',
        _keep
            ? 'The original is backed up and kept until you remove it.'
            : 'The original is backed up for 3 days, then deleted automatically.',
        'Replace',
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    await _vc?.pause();
    _say('Trimming...');
    try {
      final j = await api.post('/api/trim', {
        'p': path,
        'start': _start,
        'end': _end,
        'mode': _exact ? 'exact' : 'fast',
        'action': _copy ? 'copy' : 'replace',
        'keep': _keep,
      });
      final id = j['id'];
      if (id == null) throw (j['error'] ?? 'Trim failed');
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        final r = await api.get('/api/job', query: {'id': '$id'});
        if (r['state'] == 'running') continue;
        final done = r['state'] == 'done';
        if (done && !_copy && mounted) await _open(path);
        _say((r['msg'] ?? '').toString(), err: !done);
        break;
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    final api = _api, path = _path;
    if (api == null || path == null || _busy) return;
    if (!await _confirm('Put the original back?', 'The trimmed version is replaced by the original clip.', 'Restore')) {
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await api.post('/api/restore', {'p': path});
      if (r['ok'] == true) {
        await _open(path);
        _say('Original restored.');
      } else {
        _say((r['error'] ?? 'Restore failed').toString(), err: true);
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete() async {
    final api = _api, path = _path;
    if (api == null || path == null || _busy) return;
    final ok = await _confirm(
      'Delete this clip?',
      'It goes to the bin on the server and is removed for good after 3 days. You can undo right after deleting.',
      'Delete',
    );
    if (!ok) return;
    setState(() => _busy = true);
    await _vc?.pause();
    try {
      final r = await api.post('/api/delete', {'p': path});
      if (r['ok'] != true) throw (r['error'] ?? 'Delete failed');
      if (path == _firstPath) _firstDeleted = true;
      FladderSnack.show(
        'Clip moved to the bin (kept ${r['days'] ?? 3} days).',
        actionLabel: 'Undo',
        onActionPressed: () {
          api.post('/api/undelete', {'p': path}).then((u) {
            if (u['ok'] == true) {
              if (path == _firstPath) _firstDeleted = false;
              FladderSnack.show('Clip put back.');
            }
          }).catchError((_) {});
        },
      );
      if (_left >= 0 && mounted) {
        setState(() => _busy = false);
        await _next();
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Goes to the newest clip that has not been reviewed yet. [keep] first marks the current one as reviewed.
  Future<void> _next({bool keep = false}) async {
    final api = _api, cur = _path;
    if (api == null || _busy) return;
    setState(() => _busy = true);
    await _vc?.pause();
    try {
      if (keep && cur != null) await api.post('/api/keep', {'p': cur});
      if (cur != null) _skipped.add(cur);
      final q = await api.get('/api/queue');
      final items = q['items'];
      String? nextPath;
      var nextName = '';
      if (items is List) {
        for (final it in items) {
          if (it is Map && it['p'] is String && !_skipped.contains(it['p'])) {
            nextPath = it['p'] as String;
            nextName = (it['n'] ?? '').toString();
            break;
          }
        }
      }
      final left = q['left'];
      _left = left is num ? left.toInt() : 0;
      if (nextPath == null) {
        _say('Nothing left to review.');
      } else {
        await _open(nextPath);
        _title = nextName.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
        _say('');
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editUrl() async {
    final c = TextEditingController(text: _api?.base ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trimmer address'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            hintText: 'http://192.168.0.124:8199',
            helperText: 'Leave empty to use the Jellyfin server, port 8199',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    await TrimmerApi.setBase(v);
    await _init();
  }

  String _restoreLabel() {
    final bk = _bk;
    if (bk == null || bk['keep'] == true) return 'Restore original';
    final t = bk['t'];
    if (t is! num) return 'Restore original';
    final d = DateTime.fromMillisecondsSinceEpoch((t.toInt() + 3 * 86400) * 1000);
    return 'Restore original (until ${d.day}/${d.month})';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_firstDeleted);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_left >= 0)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text('$_left to review', style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
            IconButton(
              onPressed: _editUrl,
              icon: const Icon(Icons.settings_ethernet),
              tooltip: 'Trimmer address',
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView(context)
                : _editor(context),
      ),
    );
  }

  Widget _errorView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not open the trimmer${_api == null ? '' : ' at ${_api!.base}'}', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(_error ?? '', textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: _init, child: const Text('Retry')),
                OutlinedButton(onPressed: _editUrl, child: const Text('Change address')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _editor(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vc = _vc;
    final ready = vc != null && vc.value.isInitialized;
    final playing = ready && vc.value.isPlaying;
    final maxVideoHeight = MediaQuery.of(context).size.height * 0.42;

    Widget small(String label, VoidCallback onTap) => OutlinedButton(
          onPressed: ready && !_busy ? onTap : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label, maxLines: 1),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (ready)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxVideoHeight),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: vc.value.aspectRatio <= 0 ? 16 / 9 : vc.value.aspectRatio,
                  child: GestureDetector(
                    onTap: _togglePlay,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(vc),
                        if (vc.value.isBuffering && playing) const CircularProgressIndicator(),
                        if (!playing)
                          const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('${_fmt(_pos)} / ${_fmt(_dur)}', style: theme.textTheme.labelLarge),
            const Spacer(),
            ActionChip(
              avatar: Icon(_usingLite ? Icons.data_saver_on : Icons.hd, size: 18),
              label: Text(_fullQuality ? 'Full quality' : (_usingLite ? 'Small preview' : 'Original')),
              tooltip: 'The cut is always made on the original clip',
              onPressed: _busy ? null : _toggleQuality,
            ),
          ],
        ),
        _TrimBar(
          duration: _dur,
          start: _start,
          end: _end,
          position: _pos,
          onGrab: _onGrab,
          onMove: _onMove,
          onRelease: _onRelease,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Start ${_fmt(_start)}'),
            Text('Keeps ${_fmt(_end - _start)}', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
            Text('End ${_fmt(_end)}'),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Play from the start of the cut',
              onPressed: ready ? _playFromStart : null,
              icon: const Icon(Icons.first_page),
            ),
            IconButton(
              tooltip: 'One frame back',
              onPressed: ready ? () => _step(-1 / 30) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton.filled(
              iconSize: 32,
              tooltip: playing ? 'Pause' : 'Play the cut',
              onPressed: ready ? _togglePlay : null,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            IconButton(
              tooltip: 'One frame forward',
              onPressed: ready ? () => _step(1 / 30) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            IconButton(
              tooltip: 'Play the last 2 seconds of the cut',
              onPressed: ready ? _playEnding : null,
              icon: const Icon(Icons.last_page),
            ),
            IconButton(
              tooltip: _loop ? 'Repeating the cut' : 'Stops at the end of the cut',
              isSelected: _loop,
              onPressed: () => setState(() => _loop = !_loop),
              icon: const Icon(Icons.repeat),
              selectedIcon: const Icon(Icons.repeat_on),
            ),
            TextButton(
              onPressed: ready ? _cycleSpeed : null,
              child: Text('${_speeds[_speed]}x'.replaceAll('.0x', 'x')),
            ),
          ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(width: 48, child: Text('Start', style: theme.textTheme.labelLarge)),
            small('-0.1s', () => _setStart(_start - 0.1)),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.tonal(
                onPressed: ready && !_busy ? () => _setStart(_pos, show: false) : null,
                child: const Text('Start here', maxLines: 1),
              ),
            ),
            const SizedBox(width: 6),
            small('+0.1s', () => _setStart(_start + 0.1)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(width: 48, child: Text('End', style: theme.textTheme.labelLarge)),
            small('-0.1s', () => _setEnd(_end - 0.1)),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.tonal(
                onPressed: ready && !_busy ? () => _setEnd(_pos, show: false) : null,
                child: const Text('End here', maxLines: 1),
              ),
            ),
            const SizedBox(width: 6),
            small('+0.1s', () => _setEnd(_end + 0.1)),
          ],
        ),
        const SizedBox(height: 14),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Fast cut')),
            ButtonSegment(value: true, label: Text('Exact (re-encode)')),
          ],
          selected: {_exact},
          onSelectionChanged: (s) => setState(() => _exact = s.first),
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Replace clip')),
            ButtonSegment(value: true, label: Text('Save as a copy')),
          ],
          selected: {_copy},
          onSelectionChanged: (s) => setState(() => _copy = s.first),
        ),
        if (!_copy)
          CheckboxListTile(
            value: _keep,
            onChanged: (v) => setState(() => _keep = v ?? false),
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Keep the original (no auto-delete after 3 days)'),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: ready && !_busy ? _save : null,
          icon: const Icon(Icons.content_cut),
          label: Text(_busy ? 'Working...' : 'Save cut'),
        ),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: _msgErr ? scheme.error : scheme.primary),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _next(keep: true),
                child: const Text('Fine as it is, next', maxLines: 1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _next,
                child: const Text('Next to review', maxLines: 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (_hasBackup)
              Expanded(
                child: TextButton(onPressed: _busy ? null : _restore, child: Text(_restoreLabel(), maxLines: 1)),
              ),
            Expanded(
              child: TextButton.icon(
                onPressed: _busy ? null : _delete,
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete clip'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One bar for everything: the kept part is highlighted, its two ends are handles, the line is the playhead.
/// Drag a handle to move the cut, drag or tap anywhere else to move the playhead.
class _TrimBar extends StatefulWidget {
  final double duration;
  final double start;
  final double end;
  final double position;
  final void Function(_Grab what) onGrab;
  final void Function(_Grab what, double seconds) onMove;
  final void Function(_Grab what) onRelease;

  const _TrimBar({
    required this.duration,
    required this.start,
    required this.end,
    required this.position,
    required this.onGrab,
    required this.onMove,
    required this.onRelease,
  });

  @override
  State<_TrimBar> createState() => _TrimBarState();
}

class _TrimBarState extends State<_TrimBar> {
  static const double _pad = 16;
  static const double _reach = 26;
  _Grab? _grab;

  double _toSec(double dx, double width) {
    final usable = math.max(1.0, width - 2 * _pad);
    return ((dx - _pad) / usable).clamp(0.0, 1.0).toDouble() * widget.duration;
  }

  double _toX(double sec, double width) {
    final usable = math.max(1.0, width - 2 * _pad);
    return _pad + (widget.duration <= 0 ? 0.0 : (sec / widget.duration).clamp(0.0, 1.0).toDouble()) * usable;
  }

  _Grab _pick(double dx, double width) {
    final sx = _toX(widget.start, width), ex = _toX(widget.end, width);
    // the handles sit just outside the kept part, so measure from their middles
    final ds = (dx - (sx - 6)).abs(), de = (dx - (ex + 6)).abs();
    if (ds > _reach && de > _reach) return _Grab.head;
    return ds <= de ? _Grab.start : _Grab.end;
  }

  void _release() {
    final g = _grab;
    _grab = null;
    if (g != null) widget.onRelease(g);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            final g = _pick(d.localPosition.dx, w);
            _grab = g;
            widget.onGrab(g);
            widget.onMove(g, _toSec(d.localPosition.dx, w));
          },
          onHorizontalDragUpdate: (d) {
            final g = _grab;
            if (g != null) widget.onMove(g, _toSec(d.localPosition.dx, w));
          },
          onHorizontalDragEnd: (_) => _release(),
          onHorizontalDragCancel: _release,
          onTapUp: (d) {
            widget.onGrab(_Grab.head);
            widget.onMove(_Grab.head, _toSec(d.localPosition.dx, w));
            widget.onRelease(_Grab.head);
          },
          child: CustomPaint(
            size: Size(w, 68),
            painter: _TrimPainter(
              duration: widget.duration,
              start: widget.start,
              end: widget.end,
              position: widget.position,
              pad: _pad,
              scheme: scheme,
              active: _grab,
            ),
          ),
        );
      },
    );
  }
}

class _TrimPainter extends CustomPainter {
  final double duration;
  final double start;
  final double end;
  final double position;
  final double pad;
  final ColorScheme scheme;
  final _Grab? active;

  _TrimPainter({
    required this.duration,
    required this.start,
    required this.end,
    required this.position,
    required this.pad,
    required this.scheme,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final usable = math.max(1.0, size.width - 2 * pad);
    double x(double s) => pad + (duration <= 0 ? 0.0 : (s / duration).clamp(0.0, 1.0).toDouble()) * usable;
    const top = 18.0;
    final bottom = size.height - 18.0;
    final sx = x(start), ex = x(end), px = x(position);

    final track = RRect.fromLTRBR(pad, top, size.width - pad, bottom, const Radius.circular(6));
    canvas.drawRRect(track, Paint()..color = scheme.surfaceContainerHighest);
    canvas.drawRect(Rect.fromLTRB(sx, top, ex, bottom), Paint()..color = scheme.primary.withValues(alpha: 0.38));
    final edge = Paint()
      ..color = scheme.primary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(sx, top), Offset(ex, top), edge);
    canvas.drawLine(Offset(sx, bottom), Offset(ex, bottom), edge);

    void handle(double hx, bool isStart) {
      final grabbed = active == (isStart ? _Grab.start : _Grab.end);
      final wide = grabbed ? 14.0 : 12.0;
      final r = RRect.fromLTRBR(
        isStart ? hx - wide : hx,
        top - 7,
        isStart ? hx : hx + wide,
        bottom + 7,
        const Radius.circular(4),
      );
      canvas.drawRRect(r, Paint()..color = scheme.primary);
      final gx = isStart ? hx - wide / 2 : hx + wide / 2;
      canvas.drawLine(
        Offset(gx, top + 6),
        Offset(gx, bottom - 6),
        Paint()
          ..color = scheme.onPrimary
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    handle(sx, true);
    handle(ex, false);

    final head = Paint()
      ..color = scheme.onSurface
      ..strokeWidth = 2;
    canvas.drawLine(Offset(px, top - 12), Offset(px, bottom + 12), head);
    canvas.drawCircle(Offset(px, top - 12), 4.5, head);
  }

  @override
  bool shouldRepaint(covariant _TrimPainter old) =>
      old.duration != duration ||
      old.start != start ||
      old.end != end ||
      old.position != position ||
      old.active != active ||
      old.scheme != scheme;
}
