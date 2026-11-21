import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
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

  static const MethodChannel _pipChannel =
      MethodChannel('swipe_player/pip');

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
  bool _isPipMode = false;
  bool _holdSpeedActive = false;

  double _volume = 1.0;
  double _speed = 1.0;
  double _brightness = 1.0;

  String? _error;
  String? _folderUri;
  final List<String> _folderUris = [];
  String? _lastVideoUri;

  DateTime _lastProgressSave =
      DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _unlockTimer;

  static const Set<String> _extensions = {
    'mp4', 'm4v', 'mov', 'mkv', 'avi',
    'webm', '3gp', 'mpeg', 'mpg', 'ts',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        final active = call.arguments?['isInPipMode'] == true;
        if (mounted) {
          setState(() => _isPipMode = active);
        }
      }
    });

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      _prefs = await SharedPreferences.getInstance();

      _folderUri = _prefs!.getString('folderUri');
      _folderUris
        ..clear()
        ..addAll(_prefs!.getStringList('folderUris') ??
            (_folderUri == null ? <String>[] : <String>[_folderUri!]));
      _lastVideoUri = _prefs!.getString('lastVideoUri');

      final savedPosition = _prefs!.getDouble('lastPosition') ?? 0;

      _repeat = _prefs!.getBool('repeat') ?? false;
      _autoplay = _prefs!.getBool('autoplay') ?? true;
      _savePosition = _prefs!.getBool('savePosition') ?? true;
      _volume = _prefs!.getDouble('volume') ?? 1.0;
      _speed = _prefs!.getDouble('speed') ?? 1.0;
      _brightness = _prefs!.getDouble('brightness') ?? 1.0;
      _coverMode = _prefs!.getBool('coverMode') ?? false;

      await ScreenBrightness.instance
          .setApplicationScreenBrightness(_brightness);

      final permissions = await _saf.persistedPermissions();
      final readableUris = permissions
          .where((p) => p.read)
          .map((p) => p.uri)
          .toSet();

      final candidates = _folderUris
          .where((uri) => readableUris.contains(uri))
          .toList();

      // Backward compatibility with the previous single-folder setting.
      if (candidates.isEmpty && _folderUri != null &&
          readableUris.contains(_folderUri)) {
        candidates.add(_folderUri!);
      }

      if (candidates.isNotEmpty) {
        _savedPosition = savedPosition;
        await _loadFolders(candidates, restoring: true);
        return;
      }

      if (mounted) {
        setState(() {
          _loading = false;
          _error = readableUris.isEmpty
              ? 'اختَر مجلد الفيديوهات للبدء.'
              : 'تعذر فتح المجلدات المحفوظة. اختَر المجلدات مرة أخرى.';
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

  double _savedPosition = 0;

  Future<void> _pickFolder() async {
    if (_loading) return;

    try {
      final folder = await _saf.pickDirectory(persistablePermission: true);
      if (folder == null) return;

      // Save the grant and its position immediately, even if the folder
      // currently contains no supported videos.
      if (!_folderUris.contains(folder.uri)) {
        _folderUris.add(folder.uri);
      }
      _folderUri = folder.uri;
      await _prefs?.setStringList('folderUris', _folderUris);
      await _prefs?.setString('folderUri', folder.uri);

      await _loadFolders(List<String>.from(_folderUris));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'تعذر اختيار المجلد: $e');
    }
  }

  Future<void> _loadFolders(
    List<String> folderUris, {
    bool restoring = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final foundVideos = <SafDocumentFile>[];
      final validUris = <String>[];

      // Walk folders in the exact order they were first selected.
      for (final uri in folderUris) {
        try {
          final folder = await _saf.stat(uri);
          if (folder == null || !folder.isDir) continue;
          validUris.add(folder.uri);

          await for (final entry in _saf.walk(folder.uri)) {
            final file = entry.file;
            if (file.isDir) continue;

            final extension = file.name.contains('.')
                ? file.name.split('.').last.toLowerCase()
                : '';

            if (_extensions.contains(extension) &&
                !foundVideos.any((v) => v.uri == file.uri)) {
              foundVideos.add(file);
            }
          }
        } catch (_) {
          // Keep processing the remaining selected folders.
        }
      }

      if (!mounted) return;

      _folderUris
        ..clear()
        ..addAll(validUris);
      _folderUri = validUris.isEmpty ? null : validUris.first;
      await _prefs?.setStringList('folderUris', _folderUris);
      if (_folderUri != null) {
        await _prefs?.setString('folderUri', _folderUri!);
      }

      if (foundVideos.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'لم يتم العثور على فيديوهات داخل المجلدات المختارة.';
        });
        return;
      }

      await _disposeCurrentVideo();

      _videos
        ..clear()
        ..addAll(foundVideos);

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
        _error = 'تعذر قراءة المجلدات: $e';
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

      if (!await localFile.exists() ||
          await localFile.length() == 0) {
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

  Future<void> _askResume(
    VideoPlayerController controller,
  ) async {
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
      await controller.seekTo(
        Duration(milliseconds: _savedPosition.toInt()),
      );
    } else {
      await controller.seekTo(Duration.zero);
    }

    await controller.play();
  }

  void _videoListener() {
    final controller = _controller;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

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
    if (_locked || _isPipMode || _holdSpeedActive) return;

    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }

    setState(() {});
  }

  Future<void> _seekTo(double milliseconds) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

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

  // سرعة مؤقتة أثناء الضغط المطوّل.
  Future<void> _setTemporarySpeed(double speed) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    try {
      await controller.setPlaybackSpeed(speed);
    } catch (_) {}
  }

  void _startHoldSpeed(LongPressStartDetails details) {
    if (_locked || _isPipMode) return;

    _holdSpeedActive = true;
    _setTemporarySpeed(2.0);

    if (mounted) setState(() {});
  }

  void _updateHoldSpeed(LongPressMoveUpdateDetails details) {
    if (!_holdSpeedActive) return;

    final dy = details.offsetFromOrigin.dy;

    if (dy <= -90) {
      _setTemporarySpeed(8.0);
    } else if (dy <= -50) {
      _setTemporarySpeed(4.0);
    } else if (dy <= -20) {
      _setTemporarySpeed(2.0);
    } else if (dy >= 110) {
      _setTemporarySpeed(0.5);
    } else if (dy >= 80) {
      _setTemporarySpeed(0.75);
    } else if (dy >= 50) {
      _setTemporarySpeed(1.0);
    } else if (dy >= 20) {
      _setTemporarySpeed(1.5);
    } else {
      _setTemporarySpeed(2.0);
    }
  }

  void _endHoldSpeed(LongPressEndDetails details) {
    _restoreHoldSpeed();
  }

  void _cancelHoldSpeed() {
    _restoreHoldSpeed();
  }

  void _restoreHoldSpeed() {
    if (!_holdSpeedActive) return;

    _holdSpeedActive = false;
    _setTemporarySpeed(_speed);

    if (mounted) setState(() {});
  }

  Future<void> _openMusic() async {
    if (_locked || _isPipMode) return;
    final wasPlaying = _controller?.value.isPlaying ?? false;
    if (wasPlaying) await _controller?.pause();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const MusicLibraryPage(),
      ),
    );
    if (mounted && wasPlaying && !_locked && !_isPipMode) {
      await _controller?.play();
    }
  }

  Future<void> _showVideoList() async {
    if (_locked || _isPipMode || _videos.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202020),
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'قائمة الفيديوهات',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _videos.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: Icon(
                      index == _currentIndex ? Icons.play_circle_fill : Icons.play_circle_outline,
                      color: index == _currentIndex ? Colors.greenAccent : Colors.white70,
                    ),
                    title: Text(
                      _videos[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: index == _currentIndex,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (index == _currentIndex) return;
                      _pageController.jumpToPage(index);
                      _openVideo(index);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _enterPictureInPicture() async {
    if (_locked || _controller == null ||
        !_controller!.value.isInitialized) {
      return;
    }

    final videoSize = _controller!.value.size;
    final width = videoSize.width.round().clamp(1, 10000);
    final height = videoSize.height.round().clamp(1, 10000);

    try {
      final success = await _pipChannel.invokeMethod<bool>(
        'enterPip',
        {
          'width': width,
          'height': height,
        },
      );

      if (success != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تشغيل النافذة العائمة على هذا الجهاز.'),
          ),
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('النافذة العائمة غير متاحة: ${e.message ?? ''}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر تشغيل النافذة العائمة.'),
        ),
      );
    }
  }

  void _lockChildren() {
    setState(() => _locked = true);
  }

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
    if (_locked || _isPipMode) return;

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
                      title: const Text('إضافة مجلد فيديوهات'),
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
                          return const ColoredBox(
                            color: Colors.black,
                          );
                        }

                        final size = controller.value.size;

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _togglePlayback,
                          onLongPressStart: _startHoldSpeed,
                          onLongPressMoveUpdate: _updateHoldSpeed,
                          onLongPressEnd: _endHoldSpeed,
                          onLongPressCancel: _cancelHoldSpeed,
                          child: Center(
                            child: InteractiveViewer(
                              key: ValueKey(index),
                              minScale: 1,
                              maxScale: 4,
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

                  if (_loading && !_isPipMode)
                    const Center(
                      child: CircularProgressIndicator(),
                    ),

                  if (_error != null && !_isPipMode)
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

                  if (!_locked && !_isPipMode) ...[
                    Positioned(
                      right: 8,
                      top: MediaQuery.of(context).size.height * 0.42,
                      child: IconButton.filledTonal(
                        onPressed: _showVideoList,
                        icon: const Icon(Icons.more_vert),
                        tooltip: 'قائمة الفيديوهات',
                      ),
                    ),
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
                      left: 64,
                      child: IconButton.filledTonal(
                        onPressed: _openMusic,
                        icon: const Icon(Icons.library_music),
                        tooltip: 'مشغل الموسيقى',
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
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
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
                                    ),
                                    IconButton(
                                      onPressed: _enterPictureInPicture,
                                      icon: const Icon(
                                        Icons.picture_in_picture_alt,
                                        color: Colors.white,
                                      ),
                                      tooltip: 'نافذة عائمة',
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                  ],

                  if (_locked && !_isPipMode) ...[
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

                  if (_holdSpeedActive && !_isPipMode)
                    Positioned(
                      top: 60,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 8,
                            ),
                            child: Text(
                              'سرعة مؤقتة',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                          ),
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
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _openMusic,
              icon: const Icon(Icons.library_music),
              label: const Text('فتح مشغل الموسيقى'),
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

class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  static const MethodChannel _musicChannel = MethodChannel('swipe_player/music');
  static const Set<String> _audioExtensions = {
    'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'opus', 'amr', '3gp',
  };

  final Saf _saf = Saf();
  final AudioPlayer _player = AudioPlayer();
  final List<SafDocumentFile> _tracks = [];
  final List<String> _folderUris = [];
  Directory? _tempDirectory;
  File? _currentLocalFile;
  int _currentIndex = -1;
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _restoreMusicFolders();
  }

  Future<void> _restoreMusicFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _folderUris
        ..clear()
        ..addAll(prefs.getStringList('musicFolderUris') ?? <String>[]);
      final permissions = await _saf.persistedPermissions();
      final readable = permissions.where((p) => p.read).map((p) => p.uri).toSet();
      final valid = _folderUris.where(readable.contains).toList();
      await _loadMusicFolders(valid, restoring: true);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _message = 'تعذر استعادة مجلدات الموسيقى: $e'; });
    }
  }

  Future<void> _pickMusicFolder() async {
    try {
      final folder = await _saf.pickDirectory(persistablePermission: true);
      if (folder == null) return;
      if (!_folderUris.contains(folder.uri)) _folderUris.add(folder.uri);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('musicFolderUris', _folderUris);
      await _loadMusicFolders(List<String>.from(_folderUris));
    } catch (e) {
      if (mounted) setState(() => _message = 'تعذر اختيار المجلد: $e');
    }
  }

  Future<void> _loadMusicFolders(List<String> folders, {bool restoring = false}) async {
    if (mounted) setState(() { _loading = true; _message = null; });
    final found = <SafDocumentFile>[];
    final valid = <String>[];
    for (final uri in folders) {
      try {
        final folder = await _saf.stat(uri);
        if (folder == null || !folder.isDir) continue;
        valid.add(folder.uri);
        await for (final entry in _saf.walk(folder.uri)) {
          final file = entry.file;
          if (file.isDir) continue;
          final ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
          if (_audioExtensions.contains(ext) && !found.any((item) => item.uri == file.uri)) {
            found.add(file);
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    _folderUris..clear()..addAll(valid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('musicFolderUris', _folderUris);
    setState(() {
      _tracks..clear()..addAll(found);
      _loading = false;
      if (found.isEmpty) _message = restoring
          ? 'اختَر مجلد الموسيقى لعرض أغانيك.'
          : 'لم يتم العثور على ملفات صوتية في المجلدات المختارة.';
    });
  }

  Future<void> _playTrack(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    try {
      _tempDirectory ??= await Directory.systemTemp.createTemp('swipe_music_');
      final track = _tracks[index];
      final safeName = track.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final local = File('${_tempDirectory!.path}/${index}_$safeName');
      await _saf.copyToLocalFile(track.uri, local.path);
      if (!await local.exists() || await local.length() == 0) {
        throw Exception('ملف الصوت فارغ أو غير متاح');
      }
      await _player.setFilePath(local.path);
      _currentLocalFile = local;
      if (!mounted) return;
      setState(() => _currentIndex = index);
      await _player.play();
    } catch (e) {
      if (mounted) setState(() => _message = 'تعذر تشغيل الملف: $e');
    }
  }

  Future<void> _setAsRingtone() async {
    final file = _currentLocalFile;
    if (file == null || !await file.exists()) {
      if (mounted) setState(() => _message = 'شغّل الأغنية أولًا ثم اختر تعيين نغمة الرنين.');
      return;
    }
    try {
      final result = await _musicChannel.invokeMethod<bool>('setRingtone', {
        'path': file.path,
        'name': _tracks[_currentIndex].name,
      });
      if (!mounted) return;
      setState(() => _message = result == true
          ? 'تم تعيين نغمة الهاتف بنجاح.'
          : 'افتح إذن تعديل إعدادات النظام، ثم ارجع واضغط تعيين النغمة مرة أخرى.');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _message = 'تعذر تعيين النغمة: ${e.message ?? ''}');
    } catch (e) {
      if (mounted) setState(() => _message = 'تعذر تعيين النغمة: $e');
    }
  }

  Future<void> _openSimRingtoneSettings() async {
    try {
      await _musicChannel.invokeMethod<void>('openSoundSettings');
    } catch (_) {
      if (mounted) setState(() => _message = 'تعذر فتح إعدادات الصوت على هذا الجهاز.');
    }
  }

  String _time(Duration? d) {
    if (d == null) return '--:--';
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _player.dispose();
    _tempDirectory?.delete(recursive: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentName = _currentIndex >= 0 && _currentIndex < _tracks.length
        ? _tracks[_currentIndex].name : 'لم يتم اختيار أغنية';
    return Scaffold(
      backgroundColor: const Color(0xFF090B18),
      appBar: AppBar(
        backgroundColor: const Color(0xFF10152B),
        title: const Text('مشغل الموسيقى'),
        actions: [
          IconButton(
            onPressed: _pickMusicFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'إضافة مجلد موسيقى',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: [Color(0xFF27245D), Color(0xFF075B70)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              children: [
                const Icon(Icons.graphic_eq, size: 52, color: Colors.white),
                const SizedBox(height: 12),
                Text(currentName, maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                StreamBuilder<Duration?>(
                  stream: _player.durationStream,
                  builder: (context, snapshot) {
                    final duration = snapshot.data ?? Duration.zero;
                    return StreamBuilder<Duration>(
                      stream: _player.positionStream,
                      builder: (context, positionSnapshot) {
                        final position = positionSnapshot.data ?? Duration.zero;
                        final max = duration.inMilliseconds.toDouble();
                        final value = position.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0);
                        return Column(children: [
                          Slider(
                            value: value,
                            min: 0,
                            max: max > 0 ? max : 1,
                            onChanged: max > 0 ? (v) => _player.seek(Duration(milliseconds: v.round())) : null,
                          ),
                          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                            Text(_time(position)),
                            Text(_time(duration)),
                          ]),
                        ]);
                      },
                    );
                  },
                ),
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                        onPressed: _currentIndex > 0 ? () => _playTrack(_currentIndex - 1) : null,
                        icon: const Icon(Icons.skip_previous, size: 34),
                      ),
                      const SizedBox(width: 18),
                      FilledButton(
                        style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(18)),
                        onPressed: _currentIndex < 0 ? null : () => playing ? _player.pause() : _player.play(),
                        child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 34),
                      ),
                      const SizedBox(width: 18),
                      IconButton(
                        onPressed: _currentIndex >= 0 && _currentIndex + 1 < _tracks.length
                            ? () => _playTrack(_currentIndex + 1) : null,
                        icon: const Icon(Icons.skip_next, size: 34),
                      ),
                    ]);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  OutlinedButton.icon(
                    onPressed: _currentIndex < 0 ? null : _setAsRingtone,
                    icon: const Icon(Icons.music_note),
                    label: const Text('تعيين نغمة الهاتف'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openSimRingtoneSettings,
                    icon: const Icon(Icons.sim_card),
                    label: const Text('إعدادات رنين الشرائح'),
                  ),
                ]),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(_message!, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.amberAccent)),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              const Expanded(child: Text('مكتبة الأغاني', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
              Text('${_tracks.length} ملف', style: const TextStyle(color: Colors.white60)),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _tracks.isEmpty
                    ? Center(child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.library_music, size: 58, color: Colors.white54),
                          const SizedBox(height: 12),
                          Text(_message ?? 'أضف مجلدًا يحتوي على الأغاني.'),
                          const SizedBox(height: 12),
                          FilledButton.icon(onPressed: _pickMusicFolder,
                              icon: const Icon(Icons.folder_open), label: const Text('اختيار مجلد الموسيقى')),
                        ]),
                      ))
                    : ListView.separated(
                        itemCount: _tracks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                        itemBuilder: (context, index) {
                          final selected = index == _currentIndex;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: selected ? const Color(0xFF00B8A9) : const Color(0xFF202846),
                              child: Icon(selected ? Icons.equalizer : Icons.music_note, color: Colors.white),
                            ),
                            title: Text(_tracks[index].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(selected ? 'يتم تشغيلها الآن' : 'ملف صوتي'),
                            onTap: () => _playTrack(index),
                            trailing: IconButton(
                              tooltip: 'تعيين كنغمة',
                              onPressed: () async {
                                await _playTrack(index);
                                await _setAsRingtone();
                              },
                              icon: const Icon(Icons.notifications_active_outlined),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

