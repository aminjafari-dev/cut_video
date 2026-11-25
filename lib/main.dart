import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const CutVideoApp());
}

/// Telegram's upload limit is 2000 MiB.
const int telegramLimitBytes = 2000 * 1024 * 1024;

/// How many parts a file of [bytes] must be split into to stay under the limit.
int partsFor(int bytes, {int limit = telegramLimitBytes}) {
  return max(1, (bytes / limit).ceil());
}

/// Human-readable size, using the same decimal GB iOS shows in Settings.
String formatGb(int bytes) => '${(bytes / 1000000000).toStringAsFixed(2)} GB';

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

  final _picker = ImagePicker();

  _Status _status = _Status.idle;
  XFile? _video;
  int _sizeBytes = 0;
  int _parts = 0;
  int _savedParts = 0;
  String _message = '';

  Future<void> _pickVideo() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return;

    final size = await file.length();
    setState(() {
      _video = file;
      _sizeBytes = size;
      _parts = partsFor(size);
      _status = _Status.picked;
    });
  }

  Future<void> _split() async {
    final video = _video;
    if (video == null) return;

    setState(() => _status = _Status.working);
    try {
      final saved = await _channel.invokeMethod<int>(
        'splitAndSave',
        {'path': video.path, 'parts': _parts},
      );
      setState(() {
        _savedParts = saved ?? _parts;
        _status = _Status.done;
      });
    } on PlatformException catch (e) {
      setState(() {
        _message = e.message ?? 'Something went wrong.';
        _status = _Status.error;
      });
    }
  }

  void _reset() {
    setState(() {
      _video = null;
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
        return Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text('Splitting into $_parts parts…', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Keep the app open until it finishes.',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );

      case _Status.done:
        return Column(
          children: [
            Icon(Icons.check_circle_outline, size: 72, color: scheme.primary),
            const SizedBox(height: 24),
            Text('Done', style: textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              '$_savedParts parts saved to your gallery.',
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

  Widget _buildAction() {
    switch (_status) {
      case _Status.idle:
        return _wideButton(label: 'Choose video', onPressed: _pickVideo);

      case _Status.picked:
        return Column(
          children: [
            _wideButton(
              label: _parts == 1 ? 'Save copy to gallery' : 'Split & save',
              onPressed: _split,
            ),
            const SizedBox(height: 8),
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

  Widget _wideButton({required String label, required VoidCallback onPressed}) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 17)),
      ),
    );
  }
}
