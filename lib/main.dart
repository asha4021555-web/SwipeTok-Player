import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saf/saf.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

class _VideoHomePageState extends State<VideoHomePage>
    with WidgetsBindingObserver {
  final Saf _saf = Saf();
  final PageController _pageController = PageController();
  final List<SafDocumentFile> _videos = [];

  VideoPlayerController? _controller;
  SharedPreferences? _prefs;
  Directory? _tempDirectory;
  File? _currentLocalFile;

  int _currentIndex = 0;
  int _openRequest = 0;
  int _lastCompletedIndex = -1;

  bool _loading = false;
  bool _locked = false;
  bool _repeat = false;
  bool _autoplay = true;
  bool _savePosition = true;
  bool _showResumePrompt = false;
  bool _coverMode = false;
  bool _unlocking = false;

  double _volume = 1.0;
  double _speed = 1.0;
  double _brightness = 1.0;
  double _savedPosition = 0;

  String? _error;
  String? _folderUri;
  String? _lastVideoUri;

  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _unlockTimer;

  static const Set<String> _extensions = {
    'mp4', 'm4v', 'mov', 'mkv', 'avi',
    'webm', '3gp', 'mpeg', 'mpg', 'ts',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      _prefs = await SharedPreferences.getInstance();

      _folderUri = _prefs!.getString('folderUri');
      _lastVideoUri = _prefs!.getString('lastVideoUri');
      _savedPosition = _prefs!.getDouble('lastPosition') ?? 0;

      _repeat = _prefs!.getBool('repeat') ?? false;
      _autoplay = _prefs!.getBool('autoplay') ?? true;
      _savePosition = _prefs!.getBool('savePosition') ?? true;
      _volume = _prefs!.getDouble('volume') ?? 1.0;
      _speed = _prefs!.getDouble('speed') ?? 1.0;
      _brightness = _prefs!.getDouble('brightness') ?? 1.0;
      _coverMode = _prefs!.getBool('coverMode') ?? false;

      await ScreenBrightness.instance
          .setApplicationScreenBrightness(_brightness);

      if (_folderUri != null) {
        final permissions = await _saf.persistedPermissions();
        final hasPermission = permissions.any(
          (p) => p.uri == _folderUri && p.read,
        );

        if (hasPermission) {
          final folder = await _saf.stat(_folderUri!);
          if (folder != null && folder.isDir) {
            await _loadFolder(folder, restoring: true);
            return;
          }
        }
      }

      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'اختَر مجلد الفيديوهات للبدء.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'تعذر استعادة المجلد المحفوظ: $e';
        });
      }
    }
  }

  Future<void> _pickFolder() async {
    if (_loading) return;

    try {
      final folder = await _saf.pickDirectory();
      if (folder == null) return;
      await _loadFolder(folder);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر اختيار المجلد: $e');
    }
  }

  Future<void> _loadFolder(
    SafDocumentFile folder, {
    bool restoring = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
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

      _videos
        ..clear()
        ..addAll(foundVideos);

      _folderUri = folder.uri;
      await _prefs?.setString('folderUri', folder.uri);

      int startIndex = 0;

      if (restoring && _lastVideoUri != null) {
        final foundIndex = foundVideos.indexWhere(
          (v) => v.uri == _lastVideoUri,
        );

        if (foundIndex >= 0) {
          startIndex = foundIndex;
          _showResumePrompt = _savedPosition > 0;
        }
      } else {
        _lastVideoUri = null;
        _savedPosition = 0;
        await _prefs?.remove('lastVideoUri');
        await _prefs?.setDouble('lastPosition', 0);
      }

      setState(() {
        _currentIndex = startIndex;
        _loading = false;
        _error = null;
      });

      if (_pageController.hasClients) {
        _pageController.jumpToPage(startIndex);
      }

      await _openVideo(startIndex);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذر قراءة المجلد: $e';
      });
    }
  }

  Future<void> _disposeCurrentVideo() async {
    final oldController = _controller;
    _controller = null;

    if (oldController != null) {
      oldController.removeListener(_videoListener);
      await oldController.dispose();
    }

    final oldFile = _currentLocalFile;
    _currentLocalFile = null;

    if (oldFile != null && await oldFile.exists()) {
      await oldFile.delete();
    }
  }

  Future<void> _openVideo(int index) async {
    if (index < 0 || index >= _videos.length) return;

    final request = ++_openRequest;

    try {
      await _disposeCurrentVideo();

      if (!mounted || request != _openRequest) return;

      setState(() {
        _currentIndex = index;
        _loading = true;
        _error = null;
      });

      _tempDirectory ??=
          await Directory.systemTemp.createTemp('swipe_player_');

      final video = _videos[index];

      final safeName = video.name.replaceAll(
        RegExp(r'[^a-zA-Z0-9._-]'),
        '_',
      );

      final localFile = File(
        '${_tempDirectory!.path}/${index}_$safeName',
      );

      await _saf.copyToLocalFile(video.uri, localFile.path);

      if (!mounted || request != _openRequest) {
        if (await localFile.exists()) {
          await localFile.delete();
        }
        return;
      }

      if (!await localFile.exists() || await localFile.length() == 0) {
        throw Exception('ملف الفيديو فارغ أو غير موجود');
      }

      _currentLocalFile = localFile;

      final controller = VideoPlayerController.file(localFile);
      _controller = controller;

      await controller.initialize();
      await controller.setLooping(_repeat);
      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);

      controller.addListener(_videoListener);

      if (!mounted || request != _openRequest) return;

      setState(() => _loading = false);

      if (_showResumePrompt && video.uri == _lastVideoUri) {
        _showResumePrompt = false;
        await _askResume(controller);
      } else {
        await controller.play();
      }
    } catch (e) {
      if (!mounted || request != _openRequest) return;

      await _disposeCurrentVideo();

      setState(() {
        _loading = false;
        _error = 'تعذر تشغيل الفيديو: $e';
      });
    }
  }

  Future<void> _askResume(VideoPlayerController controller) async {
    final choice = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('استكمال المشاهدة'),
        content: const Text(
          'هل تريد الاستمرار من آخر ثانية وصلت إليها؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('البدء من جديد'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('استمرار'),
          ),
        ],
      ),
    );

    if (!mounted || !controller.value.isInitialized) return;

    if (choice == true) {
      final position = Duration(
        milliseconds: _savedPosition.toInt(),
      );
      await controller.seekTo(position);
    } else {
      await controller.seekTo(Duration.zero);
    }

    await controller.play();
  }

  void _videoListener() {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) return;

    final value = controller.value;

    if (_savePosition) {
      final now = DateTime.now();

      if (now.difference(_lastProgressSave).inSeconds >= 2) {
        _lastProgressSave = now;
        _saveProgress();
      }
    }

    if (!value.isPlaying &&
        value.isCompleted &&
        !_repeat &&
        _autoplay &&
        _lastCompletedIndex != _currentIndex) {
      _lastCompletedIndex = _currentIndex;

      if (_currentIndex + 1 < _videos.length) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        );
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveProgress() async {
    final controller = _controller;

    if (!_savePosition ||
        controller == null ||
        !controller.value.isInitialized ||
        _videos.isEmpty) {
      return;
    }

    _lastVideoUri = _videos[_currentIndex].uri;
    _savedPosition =
        controller.value.position.inMilliseconds.toDouble();

    await _prefs?.setString('lastVideoUri', _lastVideoUri!);
    await _prefs?.setDouble('lastPosition', _savedPosition);
  }

  void _togglePlayback() {
    if (_locked) return;

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }

    setState(() {});
  }

  Future<void> _seekTo(double milliseconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    await controller.seekTo(
      Duration(milliseconds: milliseconds.toInt()),
    );
  }

  String _formatTime(Duration duration) {
    final total = duration.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _lockChildren() {
    setState(() => _locked = true);
  }

  // يبدأ حساب الثلاث ثواني من أول لمسة على علامة القفل.
  void _startUnlock() {
    if (!_locked || _unlocking) return;

    _unlocking = true;

    _unlockTimer?.cancel();
    _unlockTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _unlocking) {
        setState(() {
          _locked = false;
          _unlocking = false;
        });
      }
    });

    if (mounted) setState(() {});
  }

  void _cancelUnlock() {
    _unlocking = false;
    _unlockTimer?.cancel();

    if (mounted && _locked) {
      setState(() {});
    }
  }

  Future<void> _openSettings() async {
    if (_locked) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202020),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Widget heading(String text) => Padding(
                  padding: const EdgeInsets.only(top: 18, bottom: 8),
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );

            Widget sliderSetting(
              String title,
              double value,
              String suffix,
              ValueChanged<double> onChanged,
            ) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$title: ${(value * 100).round()}$suffix'),
                  Slider(
                    value: value.clamp(0.0, 1.0),
                    min: 0,
                    max: 1,
                    onChanged: onChanged,
                  ),
                ],
              );
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: Text(
                        'إعدادات Swipe Player',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    heading('الصورة والسطوع'),
                    sliderSetting(
                      'السطوع',
                      _brightness,
                      '%',
                      (v) async {
                        setSheetState(() => _brightness = v);
                        await ScreenBrightness.instance
                            .setApplicationScreenBrightness(v);
                        await _prefs?.setDouble('brightness', v);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('ملء الشاشة وقص الزوائد'),
                      subtitle: const Text('إيقافه يعرض الفيديو كاملًا'),
                      value: _coverMode,
                      onChanged: (v) {
                        setSheetState(() => _coverMode = v);
                        setState(() {});
                        _prefs?.setBool('coverMode', v);
                      },
                    ),
                    const Text(
                      'يمكن التكبير والتصغير بإصبعين على الفيديو.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    heading('الصوت والتشغيل'),
                    sliderSetting(
                      'الصوت',
                      _volume,
                      '%',
                      (v) async {
                        setSheetState(() => _volume = v);
                        await _controller?.setVolume(v);
                        await _prefs?.setDouble('volume', v);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('سرعة التشغيل'),
                      trailing: DropdownButton<double>(
                        value: _speed,
                        items: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('${v}x'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setSheetState(() => _speed = v);
                          await _controller?.setPlaybackSpeed(v);
                          await _prefs?.setDouble('speed', v);
                        },
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('تكرار الفيديو'),
                      value: _repeat,
                      onChanged: (v) async {
                        setSheetState(() => _repeat = v);
                        await _controller?.setLooping(v);
                        await _prefs?.setBool('repeat', v);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('التشغيل التلقائي للفيديو التالي'),
                      value: _autoplay,
                      onChanged: (v) {
                        setSheetState(() => _autoplay = v);
                        _prefs?.setBool('autoplay', v);
                      },
                    ),
                    heading('الحفظ والمجلد'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('حفظ مكان المشاهدة'),
                      value: _savePosition,
                      onChanged: (v) {
                        setSheetState(() => _savePosition = v);
                        _prefs?.setBool('savePosition', v);
                        if (!v) {
                          _prefs?.setDouble('lastPosition', 0);
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_open),
                      title: const Text('تغيير مجلد الفيديوهات'),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _pickFolder();
                      },
                    ),
                    const Divider(),
                    const Text(
                      'قفل الأطفال: اضغط علامة القفل أثناء المشاهدة. '
                      'لفكه اضغط عليها باستمرار لمدة 3 ثوانٍ.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveProgress();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlockTimer?.cancel();
    _openRequest++;
    _pageController.dispose();

    final controller = _controller;
    final tempDirectory = _tempDirectory;

    _controller = null;

    if (controller != null) {
      controller.removeListener(_videoListener);
      controller.dispose().whenComplete(() {
        tempDirectory?.delete(recursive: true);
      });
    } else {
      tempDirectory?.delete(recursive: true);
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
                  AbsorbPointer(
                    absorbing: _locked,
                    child: PageView.builder(
                      controller: _pageController,
                      scrollDirection: Axis.vertical,
                      itemCount: _videos.length,
                      onPageChanged: (index) {
                        _lastCompletedIndex = -1;
                        _openVideo(index);
                      },
                      itemBuilder: (context, index) {
                        if (index != _currentIndex ||
                            controller == null ||
                            !controller.value.isInitialized) {
                          return const ColoredBox(color: Colors.black);
                        }

                        final size = controller.value.size;

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _togglePlayback,
                          child: Center(
                            child: InteractiveViewer(
                              key: ValueKey(index),
                              minScale: 1,
                              maxScale: 4,

                              // منع السحب بإصبع واحد داخل الفيديو
                              // لتقليل تعارضه مع التنقل الرأسي.
                              panEnabled: false,
                              scaleEnabled: true,
                              child: SizedBox.expand(
                                child: FittedBox(
                                  fit: _coverMode
                                      ? BoxFit.cover
                                      : BoxFit.contain,
                                  child: SizedBox(
                                    width: size.width,
                                    height: size.height,
                                    child: VideoPlayer(controller),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),

                  if (!_locked) ...[
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton.filledTonal(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.settings),
                        tooltip: 'الإعدادات',
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: IconButton.filledTonal(
                        onPressed: _lockChildren,
                        icon: const Icon(Icons.lock_open),
                        tooltip: 'قفل الأطفال',
                      ),
                    ),
                    if (controller != null &&
                        controller.value.isInitialized)
                      Positioned(
                        bottom: 8,
                        left: 12,
                        right: 12,
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: controller,
                          builder: (context, value, child) {
                            final duration = value.duration;
                            final position = value.position;
                            final totalMs =
                                duration.inMilliseconds.toDouble();
                            final currentMs =
                                position.inMilliseconds.toDouble();
                            final remaining = duration - position;

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_formatTime(position)),
                                    Text(
                                      '-${_formatTime(remaining.isNegative ? Duration.zero : remaining)}',
                                    ),
                                    Text(_formatTime(duration)),
                                  ],
                                ),
                                Slider(
                                  value: totalMs > 0
                                      ? currentMs.clamp(0, totalMs)
                                      : 0,
                                  min: 0,
                                  max: totalMs > 0 ? totalMs : 1,
                                  onChanged:
                                      totalMs > 0 ? _seekTo : null,
                                ),
                                Text(
                                  '${_currentIndex + 1} / ${_videos.length}  •  ${_videos[_currentIndex].name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
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
                              ],
                            );
                          },
                        ),
                      ),
                  ],

                  // تعتيم الشاشة دون اعتراض اللمسات.
                  // علامة القفل وحدها تستقبل الضغط لفك القفل.
                  if (_locked) ...[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) => _startUnlock(),
                        onTapUp: (_) => _cancelUnlock(),
                        onTapCancel: _cancelUnlock,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(color: Colors.white54),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _unlocking
                                    ? Icons.lock_open
                                    : Icons.lock,
                                color: Colors.white,
                                size: 28,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _unlocking
                                    ? 'استمر في الضغط...'
                                    : 'مقفل',
                                style: const TextStyle(
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
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
