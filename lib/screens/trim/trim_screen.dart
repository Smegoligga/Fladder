import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/providers/user_provider.dart';

/// Opens the clip trimmer for [item]. The trimmer runs on the same server as Jellyfin (default port 8199).
Future<void> showTrimScreen(BuildContext context, ItemBaseModel item) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => TrimScreen(item: item)),
  );
}

class TrimScreen extends ConsumerStatefulWidget {
  final ItemBaseModel item;
  const TrimScreen({required this.item, super.key});

  @override
  ConsumerState<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends ConsumerState<TrimScreen> {
  static const _prefKey = 'trimmer_url';
  String _base = '';
  Map<String, String> _headers = {};
  String? _path;
  VideoPlayerController? _vc;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String _msg = '';
  bool _msgErr = false;
  double _dur = 1;
  RangeValues _range = const RangeValues(0, 1);
  bool _exact = false;
  bool _copy = false;
  bool _keep = false;
  Map<String, dynamic>? _bk;
  bool _hasBackup = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _vc?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = ref.read(userProvider)?.credentials;
      if (cred == null) throw 'Not logged in';
      final prefs = await SharedPreferences.getInstance();
      var base = prefs.getString(_prefKey);
      if (base == null || base.isEmpty) {
        final u = Uri.parse(cred.url);
        base = 'http://${u.host}:8199';
      }
      _base = base.replaceAll(RegExp(r'/+$'), '');
      _headers = {'Authorization': 'MediaBrowser Token="${cred.token}"'};
      final r = await _get('/api/byid?id=${Uri.encodeQueryComponent(widget.item.id)}');
      if (r['p'] == null) throw (r['error'] ?? 'This clip is not in a trimmable folder');
      _path = r['p'] as String;
      await _loadVideo();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<Map<String, dynamic>> _get(String p) async {
    final res = await http.get(Uri.parse(_base + p), headers: _headers).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) throw 'Trimmer refused the login (admin account needed)';
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(String p, Map<String, dynamic> body) async {
    final res = await http
        .post(Uri.parse(_base + p), headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) throw 'Trimmer refused the login (admin account needed)';
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> _loadVideo() async {
    final info = await _get('/api/info?p=${Uri.encodeQueryComponent(_path!)}');
    if (info['duration'] == null) throw (info['error'] ?? 'Could not read clip');
    _dur = (info['duration'] as num).toDouble();
    _range = RangeValues(0, _dur);
    _hasBackup = info['hasBackup'] == true;
    _bk = info['bk'] as Map<String, dynamic>?;
    _keep = _bk?['keep'] == true;
    final old = _vc;
    final vc = VideoPlayerController.networkUrl(
      Uri.parse('$_base/api/video?p=${Uri.encodeQueryComponent(_path!)}&t=${DateTime.now().millisecondsSinceEpoch}'),
      httpHeaders: _headers,
    );
    await vc.initialize();
    vc.addListener(() {
      if (mounted) setState(() {});
    });
    _vc = vc;
    await old?.dispose();
  }

  double get _pos => (_vc?.value.position.inMilliseconds ?? 0) / 1000.0;

  void _seek(double s) => _vc?.seekTo(Duration(milliseconds: (s.clamp(0, _dur) * 1000).round()));

  void _say(String t, {bool err = false}) => setState(() {
        _msg = t;
        _msgErr = err;
      });

  void _setStart(double v) {
    v = v.clamp(0, _dur).toDouble();
    if (v > _range.end - 0.3) return _say('Start must be before the end marker.', err: true);
    setState(() => _range = RangeValues(v, _range.end));
    _seek(v);
  }

  void _setEnd(double v) {
    v = v.clamp(0, _dur).toDouble();
    if (v < _range.start + 0.3) return _say('End must be after the start marker.', err: true);
    setState(() => _range = RangeValues(_range.start, v));
    _seek((v - 0.5).clamp(0, _dur).toDouble());
  }

  Future<void> _preview() async {
    final vc = _vc;
    if (vc == null) return;
    await vc.seekTo(Duration(milliseconds: (_range.start * 1000).round()));
    await vc.play();
    late VoidCallback l;
    l = () {
      if (_pos >= _range.end || !vc.value.isPlaying) {
        vc.pause();
        vc.removeListener(l);
      }
    };
    vc.addListener(l);
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_range.start <= 0.05 && _range.end >= _dur - 0.05) {
      return _say('Nothing to cut: start and end cover the whole clip.', err: true);
    }
    if (!_copy) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Replace the original?'),
          content: Text(_keep
              ? 'The original is backed up and kept until you remove it.'
              : 'The original is backed up and deleted automatically after 3 days.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Replace')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    _vc?.pause();
    _say('Trimming...');
    try {
      final j = await _post('/api/trim', {
        'p': _path,
        'start': _range.start,
        'end': _range.end,
        'mode': _exact ? 'exact' : 'fast',
        'action': _copy ? 'copy' : 'replace',
        'keep': _keep,
      });
      if (j['id'] == null) throw (j['error'] ?? 'Trim failed');
      while (true) {
        await Future.delayed(const Duration(milliseconds: 1200));
        final r = await _get('/api/job?id=${j['id']}');
        if (r['state'] == 'running') continue;
        final done = r['state'] == 'done';
        _say((r['msg'] ?? '').toString(), err: !done);
        if (done && !_copy) await _loadVideo();
        break;
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Put the original back?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _post('/api/restore', {'p': _path});
      if (r['ok'] == true) {
        await _loadVideo();
        _say('Original restored.');
      } else {
        _say((r['error'] ?? 'Restore failed').toString(), err: true);
      }
    } catch (e) {
      _say(e.toString(), err: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _editUrl() async {
    final c = TextEditingController(text: _base);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trimmer address'),
        content: TextField(controller: c, decoration: const InputDecoration(hintText: 'http://100.x.x.x:8199')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, v);
    _init();
  }

  String _fmt(double s) => '${s.toStringAsFixed(2)}s';

  Widget _nudge(String label, VoidCallback onTap) =>
      OutlinedButton(onPressed: onTap, child: Text(label, maxLines: 1));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final vc = _vc;
    final ready = vc != null && vc.value.isInitialized;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [IconButton(onPressed: _editUrl, icon: const Icon(Icons.settings_ethernet), tooltip: 'Trimmer address')],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Could not open the trimmer at $_base', textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                      const SizedBox(height: 16),
                      Wrap(spacing: 8, children: [
                        FilledButton(onPressed: _init, child: const Text('Retry')),
                        OutlinedButton(onPressed: _editUrl, child: const Text('Change address')),
                      ]),
                    ]),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (ready)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: vc.value.aspectRatio,
                          child: GestureDetector(
                            onTap: () => vc.value.isPlaying ? vc.pause() : vc.play(),
                            child: Stack(alignment: Alignment.center, children: [
                              VideoPlayer(vc),
                              if (!vc.value.isPlaying)
                                const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
                            ]),
                          ),
                        ),
                      ),
                    Row(children: [
                      Text('${_fmt(_pos)} / ${_fmt(_dur)}', style: Theme.of(context).textTheme.labelMedium),
                    ]),
                    Slider(value: _pos.clamp(0, _dur).toDouble(), min: 0, max: _dur, onChanged: _seek),
                    Text('Keep this part (drag the ends)', style: Theme.of(context).textTheme.labelLarge),
                    RangeSlider(
                      values: _range,
                      min: 0,
                      max: _dur,
                      activeColor: scheme.primary,
                      labels: RangeLabels(_fmt(_range.start), _fmt(_range.end)),
                      onChanged: (v) {
                        final startMoved = (v.start - _range.start).abs() > (v.end - _range.end).abs();
                        if (v.end - v.start < 0.3) return;
                        setState(() => _range = v);
                        _seek(startMoved ? v.start : (v.end - 0.5).clamp(0, _dur).toDouble());
                      },
                    ),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Start ${_fmt(_range.start)}'),
                      Text('Result ${_fmt(_range.end - _range.start)}'),
                      Text('End ${_fmt(_range.end)}'),
                    ]),
                    const SizedBox(height: 12),
                    Text('Start', style: Theme.of(context).textTheme.labelLarge),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      _nudge('-0.1s', () => _setStart(_range.start - 0.1)),
                      FilledButton.tonal(onPressed: () => _setStart(_pos), child: const Text('Start = now')),
                      _nudge('+0.1s', () => _setStart(_range.start + 0.1)),
                    ]),
                    const SizedBox(height: 8),
                    Text('End', style: Theme.of(context).textTheme.labelLarge),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      _nudge('-0.1s', () => _setEnd(_range.end - 0.1)),
                      FilledButton.tonal(onPressed: () => _setEnd(_pos), child: const Text('End = now')),
                      _nudge('+0.1s', () => _setEnd(_range.end + 0.1)),
                    ]),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Fast (keyframe)')),
                        ButtonSegment(value: true, label: Text('Exact (re-encode)')),
                      ],
                      selected: {_exact},
                      onSelectionChanged: (s) => setState(() => _exact = s.first),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Replace (backup)')),
                        ButtonSegment(value: true, label: Text('Save as new copy')),
                      ],
                      selected: {_copy},
                      onSelectionChanged: (s) => setState(() => _copy = s.first),
                    ),
                    CheckboxListTile(
                      value: _keep,
                      onChanged: (v) => setState(() => _keep = v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Keep original (no auto-delete after 3 days)'),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: OutlinedButton(onPressed: ready ? _preview : null, child: const Text('Preview cut'))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: ready && !_busy ? _save : null,
                          child: Text(_busy ? 'Working...' : 'Save'),
                        ),
                      ),
                    ]),
                    if (_hasBackup)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: TextButton(
                          onPressed: _restore,
                          child: Text(_bk == null || _bk!['keep'] == true
                              ? 'Restore original'
                              : 'Restore original (kept until ${_until()})'),
                        ),
                      ),
                    if (_msg.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_msg,
                            textAlign: TextAlign.center, style: TextStyle(color: _msgErr ? scheme.error : scheme.primary)),
                      ),
                  ],
                ),
    );
  }

  String _until() {
    final t = (_bk?['t'] as num?)?.toInt() ?? 0;
    final d = DateTime.fromMillisecondsSinceEpoch((t + 3 * 86400) * 1000);
    return '${d.day}/${d.month}';
  }
}
