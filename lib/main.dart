import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const CutVideoApp());
}

/// Telegram's upload limit is 2000 MiB.
const int telegramLimitBytes = 2000 * 1024 * 1024;

/// Red used for the destructive "split, save & delete" action.
const Color deleteRed = Color(0xFFE53935);

/// How many parts a file of [bytes] must be split into to stay under the limit.
int partsFor(int bytes, {int limit = telegramLimitBytes}) {
  return max(1, (bytes / limit).ceil());
}

/// Human-readable size, using the same decimal GB iOS shows in Settings.
String formatGb(int bytes) => '${(bytes / 1000000000).toStringAsFixed(2)} GB';

/// Short duration like "2m 05s" or "1h 03m".
String formatDuration(Duration d) {
  if (d.inHours > 0) {
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

class CutVideoApp extends StatelessWidget {
  const CutVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cut Video',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2AABEE)),
        useMaterial3: true,
      ),
      home: const SplitPage(),
    );
  }
}

class SplitPage extends StatefulWidget {
  const SplitPage({super.key});

  @override
  State<SplitPage> createState() => _SplitPageState();
}

enum _Status { idle, picked, working, done, error }

class _SplitPageState extends State<SplitPage> {
  static const _channel = MethodChannel('cut_video/splitter');
  static const _progressChannel = EventChannel('cut_video/progress');

  _Status _status = _Status.idle;
  String? _assetId;
  int _sizeBytes = 0;
  int _parts = 0;
  bool _deleteRequested = false;
  bool _originalDeleted = false;
  double _progress = 0; // 0.0 ... 1.0, overall
  Duration _elapsed = Duration.zero;
  String _message = '';

  Future<void> _pickVideo() async {
    try {
      final picked = await _channel.invokeMapMethod<String, dynamic>('pickVideo');
      if (picked == null) return; // cancelled

      final size = picked['size'] as int? ?? 0;
      if (size <= 0) {
        setState(() {
          _message = 'Could not read the size of this video.';
          _status = _Status.error;
        });
        return;
      }
      setState(() {
        _assetId = picked['assetId'] as String?;
        _sizeBytes = size;
        _parts = partsFor(size);
        _status = _Status.picked;
      });
    } on PlatformException catch (e) {
      setState(() {
        _message = e.message ?? 'Could not open the video.';
        _status = _Status.error;
      });
    }
  }

  Future<void> _split({required bool deleteOriginal}) async {
    final assetId = _assetId;
    if (assetId == null) return;

    final stopwatch = Stopwatch()..start();
    setState(() {
      _status = _Status.working;
      _deleteRequested = deleteOriginal;
      _originalDeleted = false;
      _progress = 0;
      _elapsed = Duration.zero;
    });

    final subscription = _progressChannel.receiveBroadcastStream().listen((event) {
      setState(() {
        _progress = (event as num).toDouble().clamp(0.0, 1.0);
        _elapsed = stopwatch.elapsed;
      });
    });

    try {
      final outcome = await _channel.invokeMapMethod<String, dynamic>(
        'splitAndSave',
        {
          'parts': _parts,
          'assetId': assetId,
          'delete': deleteOriginal,
        },
      );
      setState(() {
        _originalDeleted = outcome?['deleted'] == true;
        _status = _Status.done;
      });
    } on PlatformException catch (e) {
      setState(() {
        _message = e.message ?? 'Something went wrong.';
        _status = _Status.error;
      });
    } finally {
      stopwatch.stop();
      await subscription.cancel();
    }
  }

  /// Estimated time left, extrapolated from the time spent so far.
  Duration? _estimateRemaining() {
    if (_progress < 0.02) return null;
    final micros = _elapsed.inMicroseconds * (1 - _progress) / _progress;
    return Duration(microseconds: micros.round());
  }

  void _reset() {
    setState(() {
      _assetId = null;
      _status = _Status.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(),
              _buildCenter(scheme, textTheme),
              const Spacer(),
              _buildAction(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenter(ColorScheme scheme, TextTheme textTheme) {
    switch (_status) {
      case _Status.idle:
        return Column(
          children: [
            Icon(Icons.movie_outlined, size: 72, color: scheme.primary),
            const SizedBox(height: 24),
            Text('Split for Telegram', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Pick a video. It is split into parts under 2 GB and saved to your gallery.',
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case _Status.picked:
        return Column(
          children: [
            Text(formatGb(_sizeBytes), style: textTheme.displayMedium),
            const SizedBox(height: 8),
            Text(
              _parts == 1
                  ? 'Already under 2 GB, no split needed.'
                  : 'Will be split into $_parts parts',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case _Status.working:
        return _buildProgress(scheme, textTheme);

      case _Status.done:
        final String detail;
        if (!_deleteRequested) {
          detail = '$_parts parts saved to your gallery.';
        } else if (_originalDeleted) {
          detail = '$_parts parts saved and the original video was deleted.';
        } else {
          detail = '$_parts parts saved. The original was kept '
              '(deletion was cancelled or not allowed).';
        }
        return Column(
          children: [
            Icon(Icons.check_circle_outline, size: 72, color: scheme.primary),
            const SizedBox(height: 24),
            Text('Done', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case _Status.error:
        return Column(
          children: [
            Icon(Icons.error_outline, size: 72, color: scheme.error),
            const SizedBox(height: 24),
            Text('Something went wrong', style: textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );
    }
  }

  Widget _buildProgress(ColorScheme scheme, TextTheme textTheme) {
    final donePercent = (_progress * 100).floor();
    final leftPercent = 100 - donePercent;
    final remaining = _estimateRemaining();
    final currentPart = min(_parts, (_progress * _parts).floor() + 1);
    final muted = textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    return Column(
      children: [
        Text('$donePercent%', style: textTheme.displayLarge),
        const SizedBox(height: 4),
        Text('Part $currentPart of $_parts', style: muted),
        const SizedBox(height: 28),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 12,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('$donePercent% done', style: muted),
            Text('$leftPercent% left', style: muted),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          remaining == null
              ? 'Estimating time left…'
              : '${formatDuration(remaining)} left',
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Keep the app open until it finishes.',
          textAlign: TextAlign.center,
          style: muted,
        ),
      ],
    );
  }

  Widget _buildAction() {
    switch (_status) {
      case _Status.idle:
        return _wideButton(label: 'Choose video', onPressed: _pickVideo);

      case _Status.picked:
        return Column(
          children: [
            _wideButton(
              label: 'Split & save',
              onPressed: () => _split(deleteOriginal: false),
            ),
            const SizedBox(height: 10),
            _wideButton(
              label: 'Split, save & delete',
              color: deleteRed,
              onPressed: () => _split(deleteOriginal: true),
            ),
            const SizedBox(height: 4),
            TextButton(onPressed: _pickVideo, child: const Text('Choose another')),
          ],
        );

      case _Status.working:
        return const SizedBox(height: 56);

      case _Status.done:
      case _Status.error:
        return _wideButton(label: 'Start over', onPressed: _reset);
    }
  }

  Widget _wideButton({
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 17)),
      ),
    );
  }
}
