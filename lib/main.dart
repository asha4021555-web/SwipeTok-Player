
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:saf/saf.dart';
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
  final Saf _saf = Saf();
  final PageController _pageController = PageController();

  final List<SafDocumentFile> _videos = [];

  VideoPlayerController? _controller;
  int? _openedFd;

  int _currentIndex = 0;
  bool _loading = false;
  String? _error;

  static const Set<String> _extensions = {
    'mp4',
    'm4v',
    'mov',
    'mkv',
    'avi',
    'webm',
    '3gp',
    'mpeg',
    'mpg',
    'ts',
  };

  Future<void> _pickFolder() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      final folder = await _saf.pickDirectory();

      if (folder == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      final foundVideos = <SafDocumentFile>[];

      await for (final entry in _saf.walk(folder.uri)) {
        final file = entry.file;

        if (file.isDir) continue;

        final extension = file.name.contains('.')
            ? file.name.split('.').last.toLowerCase()
            : '';

        if (_extensions.contains(extension)) {
          foundVideos.add(file);
        }
      }

      if (!mounted) return;

      if (foundVideos.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'لم يتم العثور على فيديوهات داخل هذا المجلد.';
        });
        return;
      }

      await _disposeCurrentVideo();

      if (!mounted) return;

      setState(() {
        _videos
          ..clear()
          ..addAll(foundVideos);
        _currentIndex = 0;
        _loading = false;
        _error = null;
      });

      await _openVideo(0);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'حدث خطأ أثناء قراءة المجلد: $e';
      });
    }
  }

  Future<void> _disposeCurrentVideo() async {
    final oldController = _controller;
    _controller = null;

    if (oldController != null) {
      await oldController.dispose();
    }

    final oldFd = _openedFd;
    _openedFd = null;

    if (oldFd != null) {
      await _saf.closeFileDescriptor(oldFd);
    }
  }

  Future<void> _openVideo(int index) async {
    if (index < 0 || index >= _videos.length) return;

    await _disposeCurrentVideo();

    if (!mounted) return;

    setState(() {
      _currentIndex = index;
      _loading = true;
      _error = null;
    });

    try {
      final video = _videos[index];

      final opened = await _saf.openFileDescriptor(
        video.uri,
        'r',
      );

      _openedFd = opened.fd;

      final controller = VideoPlayerController.file(
        File(opened.path),
      );

      _controller = controller;

      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();

      if (!mounted || _controller != controller) return;

      setState(() {
        _loading = false;
      });
    } catch (e) {
      await _disposeCurrentVideo();

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = 'تعذر تشغيل هذا الفيديو.';
      });
    }
  }

  void _togglePlayback() {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

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

    final controller = _controller;
    final fd = _openedFd;

    _controller = null;
    _openedFd = null;

    if (controller != null) {
      controller.dispose().then((_) {
        if (fd != null) {
          _saf.closeFileDescriptor(fd);
        }
      });
    } else if (fd != null) {
      _saf.closeFileDescriptor(fd);
    }

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
                        return const ColoredBox(
                          color: Colors.black,
                        );
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
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                  if (_error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: IconButton.filledTonal(
                      onPressed: _pickFolder,
                      icon: const Icon(Icons.folder_open),
                      tooltip: 'اختيار مجلد',
                    ),
                  ),
                  Positioned(
                    bottom: 20,
                    left: 16,
                    right: 16,
                    child: Text(
                      '${_currentIndex + 1} / ${_videos.length}\n'
                      '${_videos[_currentIndex].name}',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black,
                          ),
                        ],
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
            const Icon(
              Icons.video_library,
              size: 72,
              color: Colors.white70,
            ),
            const SizedBox(height: 18),
            const Text(
              'Swipe Player',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'مشغل فيديوهات بدون إنترنت\n'
              'اختَر مجلد الفيديوهات وسيتم البحث داخله تلقائيًا.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _loading ? null : _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('اختيار مجلد الفيديوهات'),
            ),
            if (_loading) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
              const SizedBox(height: 8),
              const Text('جاري البحث عن الفيديوهات...'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
