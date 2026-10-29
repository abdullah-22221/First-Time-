import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

final player = AudioPlayer();
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
final bgPath = ValueNotifier<String?>(null);
final currentTitle = ValueNotifier<String>('');

class Track {
  final String title;
  final Future<String?> Function() path;
  Track(this.title, this.path);
}

List<Track> queue = [];
int qi = -1;

String clean(String? n) =>
    (n ?? 'Unknown').replaceAll(RegExp(r'\.[^.]+$'), '');

String fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

Future<void> playTrack(List<Track> list, int i, {Duration? from}) async {
  queue = list;
  qi = i;
  final t = list[i];
  final p = await t.path();
  if (p == null) return;
  currentTitle.value = t.title;
  try {
    await player.setAudioSource(
      AudioSource.uri(Uri.file(p),
          tag: MediaItem(id: p, title: t.title, album: 'AS Player')),
      initialPosition: from,
    );
    player.play();
  } catch (_) {}
}

void playNext() {
  if (qi + 1 < queue.length) playTrack(queue, qi + 1);
}

void playPrev() {
  if (qi > 0) playTrack(queue, qi - 1);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.asplayer.audio',
    androidNotificationChannelName: 'AS Player',
    androidNotificationOngoing: true,
  );
  final prefs = await SharedPreferences.getInstance();
  themeMode.value =
      prefs.getBool('dark') == true ? ThemeMode.dark : ThemeMode.light;
  final b = prefs.getString('bg');
  if (b != null && File(b).existsSync()) bgPath.value = b;
  player.processingStateStream.listen((s) {
    if (s == ProcessingState.completed) playNext();
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'AS Player',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: Colors.blue,
            scaffoldBackgroundColor: Colors.white),
        darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: Colors.blue),
        home: const Home(),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<AssetEntity> videos = [];
  List<AssetEntity> audios = [];
  bool loading = true;
  bool denied = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<List<AssetEntity>> fetch(RequestType t) async {
    final ps = await PhotoManager.getAssetPathList(type: t, onlyAll: true);
    if (ps.isEmpty) return [];
    final n = await ps.first.assetCountAsync;
    return ps.first.getAssetListRange(start: 0, end: n);
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      denied = false;
    });
    final perm = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission:
            AndroidPermission(type: RequestType.all, mediaLocation: false),
      ),
    );
    if (!perm.hasAccess) {
      if (mounted) setState(() {
        loading = false;
        denied = true;
      });
      return;
    }
    final v = await fetch(RequestType.video);
    final a = await fetch(RequestType.audio);
    if (mounted) setState(() {
      videos = v;
      audios = a;
      loading = false;
    });
  }

  List<Track> tracksOf(List<AssetEntity> l) => l
      .map((a) => Track(clean(a.title), () async => (await a.originFile)?.path))
      .toList();

  Future<void> pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    if (r == null || r.files.single.path == null) return;
    final path = r.files.single.path!;
    final name = r.files.single.name;
    final ext = name.split('.').last.toLowerCase();
    const aud = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma'];
    if (aud.contains(ext)) {
      playTrack([Track(clean(name), () async => path)], 0);
    } else if (mounted) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoScreen(path: path, title: clean(name))));
    }
  }

  Future<void> pickBg() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(x.path).copy(dest);
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString('bg');
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    await prefs.setString('bg', dest);
    bgPath.value = dest;
  }

  Future<void> resetBg() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bg');
    bgPath.value = null;
  }

  Future<void> toggleTheme() async {
    final dark = themeMode.value != ThemeMode.dark;
    themeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark', dark);
  }

  Widget list(List<AssetEntity> items, bool isVideo) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (denied) {
      return Center(
        child: ElevatedButton(
            onPressed: () => PhotoManager.openSetting(),
            child: const Text('Permission দিন')),
      );
    }
    if (items.isEmpty) return const Center(child: Text('কোনো ফাইল নেই'));
    final tracks = tracksOf(items);
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final a = items[i];
        return ListTile(
          leading: Icon(isVideo ? Icons.movie : Icons.music_note),
          title: Text(clean(a.title), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(fmt(a.videoDuration)),
          trailing: isVideo
              ? IconButton(
                  icon: const Icon(Icons.headphones),
                  tooltip: 'অডিও হিসেবে শুনুন',
                  onPressed: () => playTrack(tracksOf(items), i),
                )
              : null,
          onTap: () async {
            if (isVideo) {
              final f = await a.originFile;
              if (f != null && mounted) {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            VideoScreen(path: f.path, title: clean(a.title))));
              }
            } else {
              playTrack(tracks, i);
            }
          },
        );
      },
    );
  }

  Widget miniPlayer() {
    return ValueListenableBuilder<String>(
      valueListenable: currentTitle,
      builder: (_, t, __) {
        if (t.isEmpty) return const SizedBox.shrink();
        return Material(
          elevation: 8,
          child: SafeArea(
            child: Row(children: [
              const Padding(
                  padding: EdgeInsets.all(12), child: Icon(Icons.music_note)),
              Expanded(
                  child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(
                  icon: const Icon(Icons.skip_previous), onPressed: playPrev),
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (_, snap) {
                  final playing = snap.data?.playing ?? false;
                  return IconButton(
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () => playing ? player.pause() : player.play(),
                  );
                },
              ),
              IconButton(icon: const Icon(Icons.skip_next), onPressed: playNext),
            ]),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<String?>(
      valueListenable: bgPath,
      builder: (_, bg, __) {
        return Stack(fit: StackFit.expand, children: [
          if (bg != null)
            Image.file(File(bg), fit: BoxFit.cover, cacheWidth: 800),
          if (bg != null)
            Container(color: dark ? Colors.black54 : Colors.white70),
          DefaultTabController(
            length: 2,
            child: Scaffold(
              backgroundColor: bg == null ? null : Colors.transparent,
              appBar: AppBar(
                backgroundColor: bg == null ? null : Colors.transparent,
                title: const Text('AS Player'),
                actions: [
                  IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: 'ফাইল সিলেক্ট',
                      onPressed: pickFile),
                  IconButton(
                      icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
                      onPressed: toggleTheme),
                  PopupMenuButton<int>(
                    icon: const Icon(Icons.wallpaper),
                    onSelected: (v) => v == 1 ? pickBg() : resetBg(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 1, child: Text('গ্যালারি থেকে ব্যাকগ্রাউন্ড')),
                      PopupMenuItem(value: 2, child: Text('ডিফল্ট (সাদা)')),
                    ],
                  ),
                ],
                bottom: const TabBar(tabs: [
                  Tab(text: 'ভিডিও'),
                  Tab(text: 'অডিও'),
                ]),
              ),
              body: TabBarView(children: [
                list(videos, true),
                list(audios, false),
              ]),
              bottomNavigationBar: miniPlayer(),
            ),
