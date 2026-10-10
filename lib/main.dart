import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'monitor.dart';

// ---------- ?¬ê·¸?¼ìš´???œë¹„??TaskHandler (ë°˜ë³µ ????ë©”ì¸???„ë‹¬) ----------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(NolTaskHandler());
}

class NolTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain({
      'tick': timestamp.millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}

// ---------- ??----------
void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const NolApp());
}

class NolApp extends StatelessWidget {
  const NolApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7C6B),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'NOL ?ˆì•½ ê°ì‹œê¸?,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F6F5),
        appBarTheme: AppBarTheme(
          backgroundColor: const Color(0xFFF4F6F5),
          foregroundColor: scheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: scheme.outlineVariant.withValues(alpha:0.7)),
          ),
          color: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF7F9F8),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.primary, width: 1.6),
          ),
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _tab = 0;
  MonitorConfig _cfg = MonitorConfig();
  WebViewController? _web;
  final FlutterLocalNotificationsPlugin _notif = FlutterLocalNotificationsPlugin();
  final List<String> _logs = [];
  bool _monitoring = false;
  bool _checking = false;
  bool _serviceInited = false;
  DateTime? _lastStart;
  DateTime? _blockedUntil;
  int _failStreak = 0;
  Set<String> _notified = {};
  Timer? _timer;
  bool _serviceOn = false;

  final _urlCtrl = TextEditingController();
  final _tgTokenCtrl = TextEditingController();
  final _tgChatCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _init();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    _timer?.cancel();
    _urlCtrl.dispose();
    _tgTokenCtrl.dispose();
    _tgChatCtrl.dispose();
    super.dispose();
  }

  void _log(String msg) {
    final t = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    setState(() {
      _logs.add('$hh:$mm:$ss $msg');
      if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
    });
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('config');
    if (raw != null) {
      try {
        _cfg = MonitorConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    _notified = prefs.getStringList('notified')?.toSet() ?? {};
    _urlCtrl.text = _cfg.nolUrl;
    _tgTokenCtrl.text = _cfg.telegramBotToken;
    _tgChatCtrl.text = _cfg.telegramChatId;
    setState(() {});

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _notif.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (resp) {
        final url = resp.payload;
        if (url != null && url.isNotEmpty) _openUrl(url);
      },
    );
    const channel = AndroidNotificationChannel(
      'nol_found',
      '?ˆì•½ ?Œë¦¼',
      description: '?í•˜???¬ì´?¸ê? ?´ë¦¬ë©??Œë¦¼',
      importance: Importance.max,
    );
    await _notif
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..loadRequest(Uri.parse(_cfg.nolUrl));
    setState(() {});
    _log('ì¤€ë¹??„ë£Œ. ë¡œê·¸?¸í•˜?¤ë©´ ë¸Œë¼?°ì? ??—??NOL??ë¡œê·¸?¸í•˜?¸ìš”.');

    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _maybeCheck());
  }

  Future<void> _ensureService() async {
    if (_serviceInited) return;
    _serviceInited = true;
    try {
      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      } catch (_) {}
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nol_watch',
        channelName: 'NOL ê°ì‹œ ì¤?,
        channelDescription: '?ˆì•½ ê°ì‹œê°€ ?¤í–‰ ì¤‘ì…?ˆë‹¤.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('config', jsonEncode(_cfg.toJson()));
    await prefs.setStringList('notified', _notified.toList());
  }

  void _collectFromFields() {
    _cfg.nolUrl = _urlCtrl.text.trim().isEmpty ? _cfg.nolUrl : _urlCtrl.text.trim();
    _cfg.telegramBotToken = _tgTokenCtrl.text.trim();
    _cfg.telegramChatId = _tgChatCtrl.text.trim();
  }

  // ---------- ê°ì‹œ ?œì–´ ----------
  Future<void> _startMonitor() async {
    _collectFromFields();
    if (_cfg.dates.isEmpty) {
      _log('? ì§œë¥?1ê°??´ìƒ ? íƒ?˜ì„¸??');
      return;
    }
    await _ensureService();
    await _save();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: 'NOL ê°ì‹œ ì¤?,
          notificationText: '?í•˜???ë¦¬ê°€ ?˜ë©´ ?Œë ¤?œë¦½?ˆë‹¤.',
          serviceTypes: [ForegroundServiceTypes.dataSync],
          callback: startCallback,
        );
      }
      _serviceOn = true;
    } catch (e) {
      _log('?¬ê·¸?¼ìš´???œë¹„???œì‘ ?¤íŒ¨(ê°ì‹œ?????¤í–‰ ì¤‘ì—ë§??™ì‘): $e');
    }
    setState(() {
      _monitoring = true;
      _failStreak = 0;
      _blockedUntil = null;
    });
    _log('ê°ì‹œ ?œì‘ (? ì§œ ${_cfg.dates.length}ê°?Ã— 4ê°œì¡´, ${_cfg.intervalSec}ì´?ê°„ê²©)');
    _maybeCheck();
  }

  Future<void> _stopMonitor() async {
    setState(() => _monitoring = false);
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
    _serviceOn = false;
    _log('ê°ì‹œ ì¤‘ì?');
  }

  void _onTaskData(Object data) {
    if (data is Map) _maybeCheck();
  }

  void _maybeCheck() {
    if (!_monitoring || _checking) return;
    final now = DateTime.now();
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return;
    if (_lastStart != null && now.difference(_lastStart!).inSeconds < _cfg.intervalSec) return;
    _checkAll();
  }

  Future<String> _jsStr(String js) async {
    final c = _web;
    if (c == null) return '';
    try {
      final r = await c.runJavaScriptReturningResult(js);
      var s = r.toString();
      if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
        try {
          s = jsonDecode(s) as String;
        } catch (_) {}
      }
      return s;
    } catch (_) {
      return '';
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await _web?.loadRequest(Uri.parse(url));
    } catch (_) {}
    setState(() => _tab = 1);
  }

  Future<void> _checkAll() async {
    if (_checking || _web == null) return;
    _checking = true;
    _lastStart = DateTime.now();
    try {
      var allFail = true;
      for (final date in _cfg.dates) {
        DateTime checkout;
        try {
          checkout = DateTime.parse(date).add(Duration(days: _cfg.nights));
        } catch (_) {
          _log('?˜ëª»??? ì§œ ê±´ë„ˆ?€: $date');
          continue;
        }
        final co =
            '${checkout.year.toString().padLeft(4, '0')}-${checkout.month.toString().padLeft(2, '0')}-${checkout.day.toString().padLeft(2, '0')}';
        final url = buildUrl(_cfg.nolUrl, date, co, _cfg.adult, _cfg.child);
        _log('$date ?•ì¸ (??$co)');
        try {
          await _web!.loadRequest(Uri.parse(url));
        } catch (e) {
          _log('  ?˜ì´ì§€ ?´ë™ ?¤íŒ¨: $e');
          continue;
        }
        // ë³¸ë¬¸ ë¡œë”© ?€ê¸?        var body = '';
        for (var i = 0; i < 25; i++) {
          await Future.delayed(const Duration(seconds: 1));
          body = await _jsStr(jsReadText);
          if (body.length > 500) break;
        }
        final hasLogin = (await _jsStr(jsHasLogin)).toLowerCase() == 'true';
        final blocked = classifyPage(body, hasLogin);
        if (blocked == 'blocked-login') {
          _log('  ë¡œê·¸?¸ì´ ?„ìš”?©ë‹ˆ?? ë¸Œë¼?°ì? ??—??ë¡œê·¸?¸í•˜?¸ìš”.');
          allFail = false;
          continue;
        }
        if (blocked == 'load-fail' || body.length < 500) {
          _log('  ë¶ˆëŸ¬?¤ê¸° ?¤íŒ¨(IP ?¼ì‹œì°¨ë‹¨ ê°€??. ?¤ìŒ ê¸°íšŒ???¬ì‹œ??');
          continue;
        }
        allFail = false;
        // 4ê°?ì¡????œíšŒ ????³„ ?”ì—¬ ?ë¦¬ ??ì§‘ê³„
        List<String> tabs = [];
        try {
          final raw = await _jsStr(jsZoneTabs);
          final decoded = jsonDecode(raw);
          if (decoded is List) tabs = decoded.map((e) => '$e').toList();
        } catch (_) {}
        tabs = tabs.where((t) => zoneTabs.contains(t)).toList();
        final tabList = tabs.isEmpty ? <String?>[null] : tabs.cast<String?>();
        final tabAvail = <String, ({int available, int total, List<int> numbers})>{};
        for (final tab in tabList) {
          if (tab != null) {
            final r = await _jsStr(jsClickTab(tab));
            if (!r.contains('clicked')) continue;
            await Future.delayed(const Duration(seconds: 3));
          }
          for (var i = 0; i < 5; i++) {
            try {
              await _web!.runJavaScript('window.scrollBy(0, 2500)');
            } catch (_) {}
            await Future.delayed(const Duration(milliseconds: 900));
          }
          final text = await _jsStr(jsReadText);
          if (text.length < 500) continue;
          final c = countAvailability(text);
          if (tab != null) {
            tabAvail[tab] = c;
          } else {
            tabAvail['?„ì²´'] = c;
          }
        }
        if (tabAvail.isNotEmpty) {
          final cov = tabAvail.entries
              .map((e) => '${e.key} ${e.value.available}?ë¦¬'
                  '${e.value.numbers.isNotEmpty ? '(${e.value.numbers.take(8).join(',')}${e.value.numbers.length > 8 ? '?? : ''})' : ''}')
              .join(' / ');
          _log('  ?”ì—¬: $cov');
        }
        var anyAvail = false;
        for (final entry in tabAvail.entries) {
          final tab = entry.key;
          final c = entry.value;
          if (c.available > 0) {
            anyAvail = true;
            _log('  ??$date $tab ${c.available}?ë¦¬ ?¨ìŒ!');
            await _notifyAvailable(date, co, tab, c.available, c.numbers, url);
          }
        }
        if (!anyAvail) {
          if (tabAvail.isEmpty) {
            _log('  ?ˆì•½ ?•ë³´ë¥??•ì¸?????†ìŠµ?ˆë‹¤.');
          } else {
            _log('  $date ë¹ˆìë¦??†ìŒ');
          }
        }
      }
      if (allFail) {
        _failStreak++;
        final wait = _cfg.intervalSec * (1 << (_failStreak > 3 ? 3 : _failStreak));
        final capped = wait > 300 ? 300 : wait;
        _blockedUntil = DateTime.now().add(Duration(seconds: capped));
        _log('?°ì† ?¤íŒ¨ $_failStreak????$cappedì´??´ì‹(IP ë³´í˜¸).');
      } else {
        _failStreak = 0;
      }
      if (_serviceOn) {
        try {
          final t = DateTime.now();
          final stamp =
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
          await FlutterForegroundTask.updateService(
            notificationText: 'ë§ˆì?ë§??•ì¸ $stamp',
          );
        } catch (_) {}
      }
    } finally {
      _checking = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _notifyAvailable(String date, String checkout, String tab,
      int count, List<int> numbers, String url) async {
    final key = '$date|$tab';
    if (_notified.contains(key)) return;
    _notified.add(key);
    await _save();
    final numStr =
        numbers.isEmpty ? '' : ' (${numbers.take(10).join(', ')})';
    final body = '$date($checkout) $tab $count?ë¦¬ ?¨ìŒ$numStr';
    // 1) ?´ë????Œë¦¼
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'nol_found',
        '?ˆì•½ ?Œë¦¼',
        channelDescription: 'ë¹ˆìë¦¬ê? ?ê¸°ë©??Œë¦¼',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
      ),
    );
    await _notif.show(
      id: key.hashCode,
      title: 'NOL ë¹ˆìë¦?',
      body: body,
      notificationDetails: details,
      payload: url,
    );
    _log('?´ë????Œë¦¼ ë°œì†¡: $key');
    // 2) ?”ë ˆê·¸ë¨ ë¬¸ì
    await _sendTelegram('NOL ë¹ˆìë¦?\n$body\n$url');
  }

  Future<void> _sendTelegram(String text) async {
    if (!_cfg.telegramEnabled) return;
    final token = _cfg.telegramBotToken.trim();
    final chat = _cfg.telegramChatId.trim();
    if (token.isEmpty || chat.isEmpty) {
      _log('?”ë ˆê·¸ë¨ ë¯¸ì„¤??? í°/ChatID ?…ë ¥ ?„ìš”).');
      return;
    }
    try {
      final uri = Uri.parse('https://api.telegram.org/bot$token/sendMessage');
      final resp = await http
          .post(uri, body: {'chat_id': chat, 'text': text}).timeout(
              const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        _log('?”ë ˆê·¸ë¨ ?„ì†¡ ?„ë£Œ.');
      } else {
        _log('?”ë ˆê·¸ë¨ ?¤íŒ¨ (${resp.statusCode}): ${resp.body.substring(0, resp.body.length > 120 ? 120 : resp.body.length)}');
      }
    } catch (e) {
      _log('?”ë ˆê·¸ë¨ ?¤ë¥˜: $e');
    }
  }

  Future<void> _testNotif() async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'nol_found',
        '?ˆì•½ ?Œë¦¼',
        importance: Importance.max,
        priority: Priority.high,
      ),
    );
    await _notif.show(
        id: 999,
        title: '?ŒìŠ¤???Œë¦¼',
        body: '?Œë¦¼???¤ë©´ ?¤ì • ?„ë£Œ?…ë‹ˆ??',
        notificationDetails: details);
    _log('?ŒìŠ¤???Œë¦¼ ë°œì†¡.');
  }

  Future<void> _testTelegram() async {
    _collectFromFields();
    await _save();
    await _sendTelegramForced('NOL ê°ì‹œê¸??ŒìŠ¤??ë©”ì‹œì§€?…ë‹ˆ?? ?˜ì‹ ?˜ë©´ ?¤ì • ?„ë£Œ!');
  }

  Future<void> _sendTelegramForced(String text) async {
    final token = _tgTokenCtrl.text.trim();
    final chat = _tgChatCtrl.text.trim();
    if (token.isEmpty || chat.isEmpty) {
      _log('?”ë ˆê·¸ë¨ ? í°/Chat IDë¥??…ë ¥?˜ì„¸??');
      return;
    }
    try {
      final uri = Uri.parse('https://api.telegram.org/bot$token/sendMessage');
      final resp = await http
          .post(uri, body: {'chat_id': chat, 'text': text}).timeout(
              const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        _log('?”ë ˆê·¸ë¨ ?ŒìŠ¤???„ì†¡ ?„ë£Œ.');
      } else {
        _log('?”ë ˆê·¸ë¨ ?ŒìŠ¤???¤íŒ¨ (${resp.statusCode})');
      }
    } catch (e) {
      _log('?”ë ˆê·¸ë¨ ?ŒìŠ¤???¤ë¥˜: $e');
    }
  }

  /// ?¬ë ¥ ?¤ì¤‘? íƒ: ?´ë¦­?˜ë©´ ? íƒ, ?¬í´ë¦?•˜ë©??´ì œ
  Future<void> _pickDatesMulti() async {
    final tmp = _cfg.dates.toSet();
    await showDialog(
      context: context,
      builder: (ctx) => _MultiCalendarDialog(
        initial: tmp,
        onDone: (sel) {
          setState(() {
            _cfg.dates = sel.toList()..sort();
          });
          _save();
        },
      ),
    );
    setState(() {});
  }

  Widget _stepper(String label, int value, void Function(int) onChange, {int min = 0, int max = 20}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha:0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
              width: 56,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600))),
          _stepBtn(Icons.remove, value > min ? () => onChange(value - 1) : null),
          Container(
            width: 36,
            alignment: Alignment.center,
            child: Text('$value',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          _stepBtn(Icons.add, value < max ? () => onChange(value + 1) : null),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: onTap == null ? Colors.grey.shade200 : cs.primary,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon,
              size: 16,
              color: onTap == null ? Colors.grey : Colors.white),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, {String? sub, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
          ],
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          if (sub != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(sub,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.forest,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('NOL ë¹ˆìë¦?ê°ì‹œ'),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 14),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _monitoring
                  ? Colors.green.withValues(alpha:0.12)
                  : Colors.grey.withValues(alpha:0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _monitoring ? Colors.green : Colors.grey.shade300,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _monitoring ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _monitoring ? 'ê°ì‹œ ì¤? : '?€ê¸?ì¤?,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _monitoring
                        ? Colors.green.shade800
                        : Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          _settingsTab(),
          _browserTab(),
          _logTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: 'ê°ì‹œ ?¤ì •'),
          NavigationDestination(
              icon: Icon(Icons.web_outlined),
              selectedIcon: Icon(Icons.web),
              label: 'ë¸Œë¼?°ì?'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'ê¸°ë¡'),
        ],
      ),
    );
  }

  Widget _settingsTab() {
    final cs = Theme.of(context).colorScheme;
    final dates = _cfg.dates.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
      children: [
        // ?íƒœ ?”ì•½ ì¹´ë“œ
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _monitoring
                  ? [const Color(0xFF0E7C6B), const Color(0xFF14937E)]
                  : [const Color(0xFF2B3A3A), const Color(0xFF3E5452)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _monitoring ? 'ê°ì‹œê°€ ?¤í–‰ ì¤‘ì…?ˆë‹¤' : 'ê°ì‹œê°€ êº¼ì ¸ ?ˆìŠµ?ˆë‹¤',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '? ì§œ ${dates.length}??Â· 4ê°?ì¡?Â· ${_cfg.intervalSec}ì´?ê°„ê²©',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha:0.85),
                          fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _monitoring ? Colors.white : cs.primaryContainer,
                  foregroundColor:
                      _monitoring ? const Color(0xFF0E7C6B) : cs.onPrimaryContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _monitoring ? _stopMonitor : _startMonitor,
                child: Text(_monitoring ? 'ì¤‘ì?' : '?œì‘',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('?ˆì•½ ? ì§œ', sub: '?¬ë ¥?ì„œ ?¬ëŸ¬ ??? íƒ', icon: Icons.calendar_month_outlined),
              if (dates.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha:0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text('? íƒ??? ì§œê°€ ?†ìŠµ?ˆë‹¤',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in dates)
                      InputChip(
                        label: Text(d.substring(5),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13)),
                        avatar: const Icon(Icons.check, size: 15),
                        onDeleted: () async {
                          setState(() => _cfg.dates.remove(d));
                          await _save();
                        },
                        onPressed: () async {
                          setState(() => _cfg.dates.remove(d));
                          await _save();
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _pickDatesMulti,
                      icon: const Icon(Icons.calendar_month, size: 18),
                      label: Text(dates.isEmpty
                          ? '?¬ë ¥?ì„œ ? ì§œ ? íƒ'
                          : '? íƒ/?´ì œ (${dates.length}??'),
                    ),
                  ),
                  if (dates.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        setState(() => _cfg.dates.clear());
                        _notified.clear();
                        await _save();
                      },
                      child: const Text('?„ì²´ì§€?°ê¸°'),
                    ),
                  ],
                ],
              ),
              const Text('?„ë¥´ë©?? íƒ, ?¤ì‹œ ?„ë¥´ë©??´ì œ?©ë‹ˆ??',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('?™ë°• ì¡°ê±´', icon: Icons.bed_outlined),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _stepper('?™ë°•(ë°?', _cfg.nights, (v) async {
                    setState(() => _cfg.nights = v);
                    await _save();
                  }, min: 1, max: 30),
                  _stepper('?±ì¸', _cfg.adult, (v) async {
                    setState(() => _cfg.adult = v);
                    await _save();
                  }, min: 1),
                  _stepper('?„ë™', _cfg.child, (v) async {
                    setState(() => _cfg.child = v);
                    await _save();
                  }),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('?•ì¸ ì£¼ê¸°',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 10),
                  DropdownButtonHideUnderline(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        border:
                            Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButton<int>(
                        value: _cfg.intervalSec,
                        items: const [60, 120, 180, 300]
                            .map((s) => DropdownMenuItem(
                                value: s, child: Text('$sì´?)))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _cfg.intervalSec = v);
                          await _save();
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text('ì§§ì„?˜ë¡ IP ì°¨ë‹¨ ?„í—˜???½ë‹ˆ?? 120ì´?ê¶Œì¥.',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _sectionTitle('?Œë¦¼', icon: Icons.notifications_outlined),
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.smartphone,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      const Text('?´ë???,
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 8),
                      const Icon(Icons.send_outlined,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      const Text('?”ë ˆê·¸ë¨',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      Switch(
                        value: _cfg.telegramEnabled,
                        onChanged: (v) async {
                          setState(() => _cfg.telegramEnabled = v);
                          await _save();
                        },
                      ),
                    ],
                  ),
                ],
              ),
              TextField(
                controller: _tgTokenCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bot Token',
                  hintText: 'BotFather?ì„œ ë°œê¸‰ë°›ì? ? í°',
                  prefixIcon: Icon(Icons.key_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tgChatCtrl,
                decoration: const InputDecoration(
                  labelText: 'Chat ID',
                  hintText: '@userinfobot?ì„œ ?•ì¸',
                  prefixIcon: Icon(Icons.person_outline, size: 18),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: _testNotif,
                      icon: const Icon(Icons.smartphone, size: 16),
                      label: const Text('?´ë????ŒìŠ¤??)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                      onPressed: _testTelegram,
                      icon: const Icon(Icons.send_outlined, size: 16),
                      label: const Text('?”ë ˆê·¸ë¨ ?ŒìŠ¤??)),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('?ˆì•½ ?˜ì´ì§€', icon: Icons.link_outlined),
              TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                      hintText: 'https://...')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () async {
                _collectFromFields();
                await _save();
                _log('?¤ì • ?€???„ë£Œ.');
                setState(() {});
              },
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('?¤ì • ?€??),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                _notified.clear();
                await _save();
                _log('?Œë¦¼ ê¸°ë¡ ì´ˆê¸°??(?¤ìŒ ë¹ˆìë¦¬ë????¤ì‹œ ?Œë¦¼).');
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('?Œë¦¼ ì´ˆê¸°??),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  _monitoring ? Colors.red.shade600 : cs.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _monitoring ? _stopMonitor : _startMonitor,
            child: Text(_monitoring ? 'ê°ì‹œ ì¤‘ì?' : 'ê°ì‹œ ?œì‘',
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '?¤í†  A/B, ìºë¼ë°?2??4??4ê°?ì¡´ì˜ ?”ì—¬ ?ë¦¬ ?˜ë? ? ì§œë³„ë¡œ ?•ì¸?©ë‹ˆ??',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _browserTab() {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _openUrl(_cfg.nolUrl),
                icon: const Icon(Icons.login, size: 18),
                label: const Text('NOL ?´ê¸° Â· ë¡œê·¸??? ì???,
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _web?.reload(),
            ),
          ]),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: _web == null
                ? const Center(child: CircularProgressIndicator())
                : WebViewWidget(controller: _web!),
          ),
        ),
      ],
    );
  }

  Widget _logTab() {
    return Column(
      children: [
        if (_logs.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 44, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  const Text('?„ì§ ê¸°ë¡???†ìŠµ?ˆë‹¤',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('ê°ì‹œë¥??œì‘?˜ë©´ ?•ì¸ ê²°ê³¼ê°€ ?“ì…?ˆë‹¤',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              itemCount: _logs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final log = _logs[_logs.length - 1 - i]; // ìµœì‹ ???„ë¡œ
                final isHit = log.contains('??);
                final isErr = log.contains('?¤íŒ¨') || log.contains('ì°¨ë‹¨');
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: isHit
                        ? const Color(0xFFE6F4EF)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isHit
                          ? const Color(0xFF0E7C6B)
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isHit ? '?‰' : (isErr ? '? ï¸' : 'Â·'),
                          style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(log,
                            style: TextStyle(
                                fontSize: 12.5,
                                height: 1.35,
                                fontWeight: isHit
                                    ? FontWeight.w700
                                    : FontWeight.normal)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => setState(_logs.clear),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('ê¸°ë¡ ì§€?°ê¸°'),
            ),
          ),
        ),
      ],
    );
  }
}

/// ?¬ë ¥ ?¤ì¤‘? íƒ ?¤ì´?¼ë¡œê·? ? ì§œ ?´ë¦­=? íƒ, ?¬í´ë¦??´ì œ
class _MultiCalendarDialog extends StatefulWidget {
  final Set<String> initial;
  final void Function(Set<String>) onDone;
  const _MultiCalendarDialog({required this.initial, required this.onDone});

  @override
  State<_MultiCalendarDialog> createState() => _MultiCalendarDialogState();
}

class _MultiCalendarDialogState extends State<_MultiCalendarDialog> {
  late Set<String> sel;
  late DateTime month;

  @override
  void initState() {
    super.initState();
    sel = Set.of(widget.initial);
    final now = DateTime.now();
    month = DateTime(now.year, now.month);
  }

  String fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    final startOffset = first.weekday % 7; // ??0
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final todayStr = fmt(DateTime.now());
    const week = ['??, '??, '??, '??, 'ëª?, 'ê¸?, '??];
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: SizedBox(
          width: 330,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        '${month.year}.${month.month.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${sel.length}??? íƒ',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: cs.onPrimaryContainer)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() =>
                        month = DateTime(month.year, month.month - 1)),
                  ),
                  const Text('?„ë¥´ë©?? íƒ, ?¤ì‹œ ?„ë¥´ë©??´ì œ',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => setState(() =>
                        month = DateTime(month.year, month.month + 1)),
                  ),
                ],
              ),
              Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Center(
                        child: Text(week[i],
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: i == 0
                                    ? Colors.red.shade400
                                    : Colors.grey.shade600)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 7,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2),
                itemCount: startOffset + daysInMonth,
                itemBuilder: (_, i) {
                  if (i < startOffset) return const SizedBox();
                  final day = i - startOffset + 1;
                  final d = DateTime(month.year, month.month, day);
                  final s = fmt(d);
                  final isPast = s.compareTo(todayStr) < 0;
                  final isToday = s == todayStr;
                  final isSel = sel.contains(s);
                  return GestureDetector(
                    onTap: isPast
                        ? null
                        : () => setState(() {
                              if (isSel) {
                                sel.remove(s);
                              } else {
                                sel.add(s);
                              }
                            }),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSel ? cs.primary : null,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSel
                              ? cs.primary
                              : (isToday
                                  ? cs.primary
                                  : Colors.transparent),
                          width: isSel ? 1 : 1.4,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: isSel
                              ? Colors.white
                              : (isPast
                                  ? Colors.grey.shade400
                                  : Colors.black87),
                          fontWeight: isSel || isToday
                              ? FontWeight.w800
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('ì·¨ì†Œ'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        widget.onDone(sel);
                        Navigator.pop(context);
                      },
                      child: const Text('?•ì¸',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
