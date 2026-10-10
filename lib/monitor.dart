/// NOL 감시 순수 로직: 설정, 파서, URL, 판정, WebView용 JS.
/// Flutter 의존 없음 — 단위 테스트 가능.
library;

const List<String> zoneTabs = [
  '오토캠핑장 A존',
  '오토캠핑장 B존',
  '캐라반(2인)존',
  '캐라반(4인)존',
];

const List<String> negWords = ['예약마감', '마감', '매진', '품절', '완판', 'soldout'];
const List<String> posStrong = ['예약가능', '예약하기', '선택가능', '선택하기', '남은객실', '잔여'];

class MonitorConfig {
  String nolUrl;
  List<String> dates;
  String sitesRaw; // 구버전 호환용(현재 미사용)
  int nights;
  int adult;
  int child;
  int intervalSec;
  String telegramBotToken;
  String telegramChatId;
  bool telegramEnabled;
  bool phoneNotifyEnabled;

  MonitorConfig({
    this.nolUrl = 'https://nol.yanolja.com/stay/domestic/10070080',
    List<String>? dates,
    this.sitesRaw = '',
    this.nights = 1,
    this.adult = 2,
    this.child = 0,
    this.intervalSec = 120,
    this.telegramBotToken = '',
    this.telegramChatId = '',
    this.telegramEnabled = false,
    this.phoneNotifyEnabled = true,
  }) : dates = dates ?? [];

  Map<String, dynamic> toJson() => {
        'nolUrl': nolUrl,
        'dates': dates,
        'sitesRaw': sitesRaw,
        'nights': nights,
        'adult': adult,
        'child': child,
        'intervalSec': intervalSec,
        'telegramBotToken': telegramBotToken,
        'telegramChatId': telegramChatId,
        'telegramEnabled': telegramEnabled,
        'phoneNotifyEnabled': phoneNotifyEnabled,
      };

  static MonitorConfig fromJson(Map<String, dynamic> j) => MonitorConfig(
        nolUrl: ((j['nolUrl'] ?? '') as String).isEmpty
            ? 'https://nol.yanolja.com/stay/domestic/10070080'
            : (j['nolUrl'] ?? '') as String,
        dates: ((j['dates'] ?? []) as List).map((e) => '$e').toList(),
        sitesRaw: (j['sitesRaw'] ?? '') as String,
        nights: (j['nights'] ?? 1) as int,
        adult: (j['adult'] ?? 2) as int,
        child: (j['child'] ?? 0) as int,
        intervalSec: (j['intervalSec'] ?? 120) as int,
        telegramBotToken: (j['telegramBotToken'] ?? '') as String,
        telegramChatId: (j['telegramChatId'] ?? '') as String,
        telegramEnabled: (j['telegramEnabled'] ?? false) as bool,
        phoneNotifyEnabled: (j['phoneNotifyEnabled'] ?? true) as bool,
      );
}

/// "31, 32, 31-40" → ([31..40], null) / 오류 시 ([], 메시지)
(List<int>, String?) parseSites(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return (<int>[], '사이트 번호를 입력해 주세요.');
  final nums = <int>{};
  for (final tok in t.split(RegExp(r'[,\s;/]+'))) {
    if (tok.isEmpty) continue;
    final range = RegExp(r'^(\d{1,4})\s*[-~]\s*(\d{1,4})$').firstMatch(tok);
    if (range != null) {
      var a = int.parse(range.group(1)!);
      var b = int.parse(range.group(2)!);
      if (a > b) {
        final tmp = a;
        a = b;
        b = tmp;
      }
      if (b - a > 500) return (<int>[], '범위가 너무 큽니다: $tok');
      for (var i = a; i <= b; i++) {
        nums.add(i);
      }
    } else if (RegExp(r'^\d{1,4}$').hasMatch(tok)) {
      nums.add(int.parse(tok));
    } else {
      return (<int>[], '잘못된 입력: $tok (숫자 또는 31-40 형태)');
    }
  }
  if (nums.isEmpty) return (<int>[], '유효한 사이트 번호가 없습니다.');
  final list = nums.toList()..sort();
  return (list, null);
}

String addDays(String datestr, int days) {
  final d = DateTime.parse(datestr).add(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

String buildUrl(String base, String checkIn, String checkOut, int adult, int child) {
  final u = Uri.parse(base);
  final q = Map<String, String>.from(u.queryParameters);
  q['checkInDate'] = checkIn;
  q['checkOutDate'] = checkOut;
  q['adultCount'] = '$adult';
  q['childCount'] = '$child';
  return u.replace(queryParameters: q).toString();
}

/// 차단/오류 분류. null이면 정상 진행.
String? classifyPage(String text, bool hasLoginForm) {
  final t = text;
  if (RegExp(r'로그인이 필요|로그인해 주세요|로그인 후|LOGIN').hasMatch(t) && hasLoginForm) {
    return 'blocked-login';
  }
  if (t.length < 2000 &&
      RegExp(r'페이지를 불러오지 못|오류가 발생|일시적인 오류|접속이 원활하지|네트워크').hasMatch(t)) {
    return 'load-fail';
  }
  if (t.length < 3000 &&
      RegExp(r'일시적으로 서비스를 이용|잠시 후에 다시 이용|서비스 이용에 불편|RayID|이전 페이지로 돌아가기|Access Denied|Attention Required')
          .hasMatch(t)) {
    return 'load-fail';
  }
  return null;
}

class RoomVerdict {
  final Map<int, bool?> rooms; // site -> true/false/null(불명)
  final List<int> foundAll;
  RoomVerdict(this.rooms, this.foundAll);
}

/// 객실 이름("오토캠핑장 31" 등) 기준 구간 판정. 확실할 때만 true/false.
RoomVerdict extractRooms(String bodyText, List<int> wanted) {
  final text = bodyText;
  final mentions = <(int, int, int)>[]; // (start, end, number)
  final rx1 = RegExp(r'(?:오토캠핑장|캐라반|무장애캐라반|사이트)\s*(\d{1,3})');
  final rx2 = RegExp(r'(\d{1,3})\s*(?:번|호)');
  for (final m in rx1.allMatches(text)) {
    mentions.add((m.start, m.end, int.parse(m.group(1)!)));
  }
  for (final m in rx2.allMatches(text)) {
    mentions.add((m.start, m.end, int.parse(m.group(1)!)));
  }
  mentions.sort((a, b) => a.$1.compareTo(b.$1));
  final dedup = <(int, int, int)>[];
  for (final m in mentions) {
    if (dedup.isNotEmpty && m.$1 < dedup.last.$2) continue;
    dedup.add(m);
  }
  final foundAll = dedup.map((e) => e.$3).toSet().toList()..sort();
  final rooms = <int, bool?>{};
  for (final site in wanted) {
    var pos = 0, neg = 0;
    for (var i = 0; i < dedup.length; i++) {
      final (s, e, num) = dedup[i];
      if (num != site) continue;
      final segEnd = (i + 1 < dedup.length) ? dedup[i + 1].$1 : e + 600;
      final end = segEnd < e + 600 ? segEnd : e + 600;
      final seg = text.substring(s, end > text.length ? text.length : end).replaceAll(' ', '').toLowerCase();
      final weak = seg.replaceAll('주차가능', '');
      if (negWords.any(seg.contains) || seg.contains('예약불가')) {
        neg++;
      }
      if (posStrong.any(seg.contains)) {
        pos += 2;
      } else if (weak.contains('가능') && !weak.contains('불가능')) {
        pos++;
      }
    }
    if (neg > 0 && pos == 0) {
      rooms[site] = false;
    } else if (pos > 0 && neg == 0) {
      rooms[site] = true;
    } else {
      rooms[site] = null;
    }
  }
  return RoomVerdict(rooms, foundAll);
}

/// 탭 내 전체 자리 중 예약가능 개수 세기 (희망번호 불필요).
/// 반환: (예약가능 수, 전체 감지 수, 예약가능 번호목록)
({int available, int total, List<int> numbers}) countAvailability(
    String bodyText) {
  final text = bodyText;
  final mentions = <(int, int, int)>[]; // (start, end, number)
  final rx1 = RegExp(r'(?:오토캠핑장|캐라반|무장애캐라반|사이트)\s*(\d{1,3})');
  final rx2 = RegExp(r'(\d{1,3})\s*(?:번|호)');
  for (final m in rx1.allMatches(text)) {
    mentions.add((m.start, m.end, int.parse(m.group(1)!)));
  }
  for (final m in rx2.allMatches(text)) {
    mentions.add((m.start, m.end, int.parse(m.group(1)!)));
  }
  mentions.sort((a, b) => a.$1.compareTo(b.$1));
  final dedup = <(int, int, int)>[];
  for (final m in mentions) {
    if (dedup.isNotEmpty && m.$1 < dedup.last.$2) continue;
    dedup.add(m);
  }
  // 같은 번호가 여러 번 나오면 구간을 합쳐서 한 번만 판정
  final byNum = <int, List<(int, int)>>{};
  for (var i = 0; i < dedup.length; i++) {
    final (s, e, num) = dedup[i];
    final segEnd = (i + 1 < dedup.length) ? dedup[i + 1].$1 : e + 600;
    final end = segEnd < e + 600 ? segEnd : e + 600;
    byNum.putIfAbsent(num, () => []).add((s, end > text.length ? text.length : end));
  }
  final availNums = <int>[];
  for (final entry in byNum.entries) {
    var pos = 0, neg = 0;
    for (final (s, e) in entry.value) {
      final seg = text.substring(s, e).replaceAll(' ', '').toLowerCase();
      final weak = seg.replaceAll('주차가능', '');
      if (negWords.any(seg.contains) || seg.contains('예약불가')) {
        neg++;
      }
      if (posStrong.any(seg.contains)) {
        pos += 2;
      } else if (weak.contains('가능') && !weak.contains('불가능')) {
        pos++;
      }
    }
    if (pos > 0 && neg == 0) availNums.add(entry.key);
  }
  availNums.sort();
  return (
    available: availNums.length,
    total: byNum.length,
    numbers: availNums,
  );
}

// ---------------- WebView JS ----------------

const String jsReadText =
    "(() => { const b = document.body; return b ? b.innerText.slice(0, 30000) : ''; })()";

const String jsHasLogin =
    "(() => !!document.querySelector('input[type=\"password\"]'))()";

const String jsZoneTabs = r"""(() => {
  const out = [];
  const els = document.querySelectorAll('*');
  for (const el of els) {
    const t = (el.innerText || '').trim();
    if (t.length > 0 && t.length < 25 && /존$/.test(t) && !out.includes(t)) out.push(t);
  }
  return JSON.stringify(out);
})()""";

String jsClickTab(String name) {
  final escaped = name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return """(() => {
  const want = "\$NAMEXYZ";
  let best = null, bestDepth = -1;
  const els = document.querySelectorAll('*');
  for (const el of els) {
    if ((el.innerText || '').trim() !== want) continue;
    let d = 0, p = el;
    while (p && p !== document.body) { d++; p = p.parentElement; }
    if (d > bestDepth) { bestDepth = d; best = el; }
  }
  if (best) { best.click(); return 'clicked'; }
  return 'notfound';
})()"""
      .replaceAll(r'$NAMEXYZ', escaped);
}
