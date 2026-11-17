
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SwipePlayerApp());
}

class SwipePlayerApp extends StatelessWidget {
  const SwipePlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Swipe Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const VideoHomePage(),
    );
  }
}

class VideoHomePage extends StatefulWidget {
  const VideoHomePage({super.key});

  @override
  State<VideoHomePage> createState() => _VideoHomePageState();
}

class _VideoHomePageState extends State<VideoHomePage> {
  final PageController _pageController = PageController();
  final List<File> _videos = [];
  VideoPlayerController? _controller;
  int _currentIndex = 0;
  bool _loading = false;
  String? _error;

  static const _extensions = {
    'mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm', '3gp', 'mpeg', 'mpg'
  };

  Future<void> _pickVideos() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
        withData: false,
      );

      if (result == null || result.files.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      final picked = <File>[];
      for (final item in result.files) {
        final path = item.path;
        if (path == null) continue;
        final extension = path.split('.').last.toLowerCase();
        if (_extensions.contains(extension)) {
          picked.add(File(path));
        }
      }

      if (picked.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'لم يتم العثور على ملفات فيديو قابلة للفتح.';
        });
        return;
      }

      await _disposeController();
      setState(() {
        _videos
          ..clear()
          ..addAll(picked);
        _currentIndex = 0;
        _loading = false;
      });
      await _openVideo(0);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر فتح الفيديوهات: $e';
        });
      }
    }
  }

  Future<void> _disposeController() async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      await old.dispose();
    }
  }

  Future<void> _openVideo(int index) async {
    if (index < 0 || index >= _videos.length) return;

    await _disposeController();
    if (!mounted) return;

    setState(() {
      _currentIndex = index;
      _loading = true;
      _error = null;
    });

    final controller = VideoPlayerController.file(_videos[index]);
    _controller = controller;

    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (!mounted || _controller != controller) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted || _controller != controller) return;
      setState(() {
        _loading = false;
        _error = 'هذا الفيديو غير مدعوم على الجهاز أو تعذر فتحه.';
      });
    }
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _videos.isEmpty
            ? _emptyState()
            : Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    controller: _pageController,
                    scrollDirection: Axis.vertical,
                    itemCount: _videos.length,
                    onPageChanged: _openVideo,
                    itemBuilder: (context, index) {
                      if (index != _currentIndex ||
                          controller == null ||
                          !controller.value.isInitialized) {
                        return const ColoredBox(color: Colors.black);
                      }
                      final size = controller.value.size;
                      return GestureDetector(
                        onTap: _togglePlayback,
                        child: Center(
                          child: AspectRatio(
                            aspectRatio:
                                size.width > 0 && size.height > 0
                                    ? size.width / size.height
                                    : 9 / 16,
                            child: VideoPlayer(controller),
                          ),
                        ),
                      );
                    },
                  ),
                  if (_loading)
                    const Center(child: CircularProgressIndicator()),
                  if (_error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: IconButton.filledTonal(
                      onPressed: _pickVideos,
                      icon: const Icon(Icons.video_library),
                      tooltip: 'اختيار فيديوهات',
                    ),
                  ),
                  Positioned(
                    bottom: 20,
                    left: 16,
                    right: 16,
                    child: Text(
                      '${_currentIndex + 1} / ${_videos.length}\n${_videos[_currentIndex].uri.pathSegments.last}',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.video_library, size: 72, color: Colors.white70),
            const SizedBox(height: 18),
            const Text(
              'Swipe Player',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              'مشغل فيديوهات بدون إنترنت\nاختَر فيديوهات من جهازك ومرّر لأعلى أو لأسفل للتنقل.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _loading ? null : _pickVideos,
              icon: const Icon(Icons.folder_open),
              label: const Text('اختيار الفيديوهات'),
            ),
            if (_loading) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
