import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const ink = Color(0xFF172029);
const muted = Color(0xFF737F8A);
const canvas = Color(0xFFF5F6F8);
const accent = Color(0xFF147D67);
const danger = Color(0xFFB63C3C);
const categories = ['Makanan', 'Pengangkutan', 'Bil', 'Beli-belah', 'Belajar', 'Kesihatan', 'Hiburan', 'Lain-lain'];
final money = NumberFormat.currency(locale: 'ms_MY', symbol: 'RM ', decimalDigits: 2);
final dt = DateFormat('dd MMM yyyy', 'en_MY');
final monthFormatter = DateFormat('MMMM yyyy', 'ms_MY');

String monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
String iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime parseDate(Object? s) => DateTime.tryParse('$s') ?? DateTime.now();
double numv(Object? n) => n is num ? n.toDouble() : (double.tryParse('$n') ?? 0);
String uid() => '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(100000)}';
DateTime dueDate(Map<String, dynamic> bill, DateTime month) {
  final limit = DateTime(month.year, month.month + 1, 0).day;
  return DateTime(month.year, month.month, min((bill['dueDay'] as num).toInt(), limit));
}
Map<String, dynamic> asMap(Object? value) => Map<String, dynamic>.from(value as Map);

class Book extends ChangeNotifier {
  List<Map<String, dynamic>> transactions = [];
  List<Map<String, dynamic>> bills = [];
  List<Map<String, dynamic>> goals = [];
  Map<String, dynamic> payments = {};
  Map<String, dynamic> budgets = {};
  bool alerts = false;
  List<int> reminderDays = [3, 5];
  bool ready = false;
  final notifications = FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('dompetku_store_v1');
      if (raw != null) {
        final a = jsonDecode(raw) as Map<String, dynamic>;
        transactions = List<Map<String, dynamic>>.from((a['transactions'] as List? ?? []).map(asMap));
        bills = List<Map<String, dynamic>>.from((a['bills'] as List? ?? []).map(asMap));
        goals = List<Map<String, dynamic>>.from((a['goals'] as List? ?? []).map(asMap));
        payments = Map<String, dynamic>.from(a['payments'] as Map? ?? {});
        budgets = Map<String, dynamic>.from(a['budgets'] as Map? ?? {});
        alerts = a['alerts'] == true;
        final stored = a['reminderDays'];
        if (stored is List && stored.isNotEmpty) {
          reminderDays = stored.map((v) => (v as num).toInt()).where((d) => d == 3 || d == 5).toSet().toList();
          if (reminderDays.isEmpty) reminderDays = [3, 5];
        }
      }
    } catch (_) {
      // The screen stays usable even if old local data cannot be parsed.
    }
    // Release the loading screen before Android notification plugins are started.
    // Never block the first screen on notification initialization/scheduling.
    ready = true;
    notifyListeners();
    unawaited(_initializeNotifications());
  }

  Future<void> _initializeNotifications() async {
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Kuala_Lumpur'));
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await notifications.initialize(
        const InitializationSettings(android: android),
      ).timeout(const Duration(seconds: 8));
      _notificationsReady = true;
      if (alerts) {
        unawaited(refreshReminders().catchError((Object _) {}));
      }
    } catch (_) {
      // The money manager still opens if Android notifications are unavailable.
      _notificationsReady = false;
    }
  }

  Map<String, dynamic> snapshot() => {
    'transactions': transactions, 'bills': bills, 'goals': goals,
    'payments': payments, 'budgets': budgets, 'alerts': alerts,
    'reminderDays': reminderDays,
  };

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dompetku_store_v1', jsonEncode(snapshot()));
    notifyListeners();
    if (alerts && _notificationsReady) {
      unawaited(refreshReminders().catchError((Object _) {}));
    }
  }

  List<Map<String, dynamic>> txFor(DateTime month) {
    final k = monthKey(month);
    return transactions.where((e) => '${e['date']}'.startsWith(k)).toList()
      ..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
  }
  double incomes(DateTime m) => txFor(m).where((e) => e['kind'] == 'income').fold<double>(0, (a, e) => a + numv(e['amount']));
  double expenses(DateTime m) => txFor(m).where((e) => e['kind'] == 'expense').fold<double>(0, (a, e) => a + numv(e['amount']));
  double saving(DateTime m) => txFor(m).where((e) => e['kind'] == 'saving').fold<double>(0, (a, e) => a + numv(e['amount']));
  double paidBills(DateTime m) => payments.values.where((e) => '${asMap(e)['paidDate']}'.startsWith(monthKey(m))).fold(0.0, (a, e) => a + numv(asMap(e)['amount']));
  double balance(DateTime m) => incomes(m) - expenses(m) - paidBills(m) - saving(m);
  String paymentId(Map<String, dynamic> bill, DateTime m) => '${bill['id']}_${monthKey(m)}';
  Map<String, dynamic>? payment(Map<String, dynamic> bill, DateTime m) {
    final x = payments[paymentId(bill, m)];
    return x == null ? null : asMap(x);
  }
  double goalSaved(String id) => transactions.where((x) => x['kind'] == 'saving' && x['goalId'] == id).fold<double>(0, (s, e) => s + numv(e['amount']));
  double categorySpent(DateTime m, String category) {
    final txsum = txFor(m).where((x) => x['kind'] == 'expense' && x['category'] == category).fold<double>(0, (a, e) => a + numv(e['amount']));
    final billSum = payments.values.where((x) {
      final p = asMap(x);
      return '${p['paidDate']}'.startsWith(monthKey(m)) && p['category'] == category;
    }).fold(0.0, (a, e) => a + numv(asMap(e)['amount']));
    return txsum + billSum;
  }

  Future<void> exportBackup() async {
    final data = snapshot();
    final receipts = <String, String>{};
    for (final item in payments.values) {
      final p = asMap(item);
      final path = '${p['receipt'] ?? ''}';
      if (path.isNotEmpty && await File(path).exists()) {
        receipts[path.split('/').last] = base64Encode(await File(path).readAsBytes());
      }
    }
    data['receiptFiles'] = receipts;
    final tmp = await getTemporaryDirectory();
    final name = 'DompetKu_Backup_${iso(DateTime.now())}.json';
    final file = File('${tmp.path}/$name');
    await file.writeAsString(jsonEncode(data));
    await Share.shareXFiles([XFile(file.path)], text: 'Backup DompetKu: simpan di lokasi peribadi yang selamat.');
  }

  Future<bool> importBackup() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (picked == null || picked.files.single.path == null) return false;
    final raw = jsonDecode(await File(picked.files.single.path!).readAsString()) as Map<String, dynamic>;
    if (raw['transactions'] is! List || raw['bills'] is! List || raw['payments'] is! Map) {
      throw const FormatException('Format backup bukan DompetKu.');
    }
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/receipts');
    await dir.create(recursive: true);
    final files = Map<String, dynamic>.from(raw['receiptFiles'] as Map? ?? {});
    final resolved = <String, String>{};
    for (final pair in files.entries) {
      // Use a new generated name rather than trusting path data inside imported JSON.
      final ext = pair.key.toLowerCase().split('.').last;
      if (!['jpg', 'jpeg', 'png', 'pdf'].contains(ext)) continue;
      final target = File('${dir.path}/${uid()}.$ext');
      await target.writeAsBytes(base64Decode('${pair.value}'));
      resolved[pair.key] = target.path;
    }
    final restoredPayments = Map<String, dynamic>.from(raw['payments'] as Map);
    for (final key in restoredPayments.keys) {
      final payment = asMap(restoredPayments[key]);
      final original = '${payment['receipt'] ?? ''}';
      payment['receipt'] = resolved[original.split('/').last] ?? '';
      restoredPayments[key] = payment;
    }
    transactions = List<Map<String, dynamic>>.from((raw['transactions'] as List).map(asMap));
    bills = List<Map<String, dynamic>>.from((raw['bills'] as List).map(asMap));
    goals = List<Map<String, dynamic>>.from((raw['goals'] as List? ?? []).map(asMap));
    payments = restoredPayments;
    budgets = Map<String, dynamic>.from(raw['budgets'] as Map? ?? {});
    // Keep device notification preference rather than trusting imported file.
    await save();
    return true;
  }

  Future<String?> captureReceipt() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf']);
    if (result == null || result.files.single.path == null) return null;
    final src = File(result.files.single.path!);
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/receipts');
    await dir.create(recursive: true);
    final ext = result.files.single.extension?.toLowerCase() ?? 'jpg';
    final dest = File('${dir.path}/${uid()}.$ext');
    await src.copy(dest.path);
    return dest.path;
  }

  Future<void> setAlerts(bool enabled) async {
    if (enabled && !_notificationsReady) {
      await _initializeNotifications();
      if (!_notificationsReady) return;
    }
    if (enabled) {
      final android = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final allowed = await android?.requestNotificationsPermission();
      if (allowed == false) return;
    }
    alerts = enabled;
    await save();
    if (!enabled && _notificationsReady) {
      try { await notifications.cancelAll(); } catch (_) {}
    }
  }

  int alarmId(String value) {
    var h = 17;
    for (final c in value.codeUnits) { h = (h * 31 + c) & 0x7fffffff; }
    return h;
  }

  Future<void> refreshReminders() async {
    if (!ready || !_notificationsReady) return;
    try {
      await notifications.cancelAll();
    } catch (_) {
      return;
    }
    if (!alerts) return;
    final now = DateTime.now();
    for (var offset = -1; offset < 6; offset++) {
      final m = DateTime(now.year, now.month + offset, 1);
      for (final bill in bills) {
        if (payment(bill, m) != null) continue;
        for (final days in reminderDays) {
          final due = dueDate(bill, m);
          final when = DateTime(due.year, due.month, due.day + days, 9);
          if (!when.isAfter(now)) continue;
          try {
            await notifications.zonedSchedule(
              alarmId('${bill['id']}_${monthKey(m)}_$days'),
              'Bil belum dibayar (${days} hari)',
              '${bill['title']} • ${money.format(numv(bill['amount']))}. Semak jika sudah dibayar.',
              tz.TZDateTime.from(when, tz.local),
              const NotificationDetails(android: AndroidNotificationDetails(
                'bill_overdue', 'Peringatan bil', channelDescription: 'Bil lewat 3 dan 5 hari',
                importance: Importance.high, priority: Priority.high)),
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
            );
          } catch (_) { /* Notifications remain optional if blocked by Android. */ }
        }
      }
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'ms_MY';
  await initializeDateFormatting('ms_MY');
  final book = Book();
  runApp(DompetApp(book));
  unawaited(book.load());
}

class DompetApp extends StatelessWidget {
  final Book book;
  const DompetApp(this.book, {super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'DompetKu', debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true, scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: ink, surface: Colors.white),
      appBarTheme: const AppBarTheme(backgroundColor: canvas, foregroundColor: ink,
        centerTitle: false, scrolledUnderElevation: 0),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.white,
        indicatorColor: Color(0xFFE6EAED)),
      cardTheme: CardThemeData(color: Colors.white, elevation: 0,
        margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFFF3F5F7),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13)),
    ),
    home: AnimatedBuilder(
      animation: book,
      builder: (context, _) => book.ready
          ? Shell(book)
          : const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
    ),
  );
}

class Shell extends StatefulWidget {
  final Book book;
  const Shell(this.book, {super.key});
  @override State<Shell> createState() => _ShellState();
}
class _ShellState extends State<Shell> {
  int tab = 0;
  DateTime selected = DateTime(DateTime.now().year, DateTime.now().month, 1);
  Book get b => widget.book;
  void changeMonth(int step) => setState(() => selected = DateTime(selected.year, selected.month + step, 1));
  void snack(String s) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))); }

  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: b,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('DOMPETKU', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 2, color: muted)),
          Text(['Ringkasan', 'Transaksi', 'Bil bulanan', 'Bajet & Simpanan', 'Tetapan'][tab],
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -.5)),
        ]),
        actions: [IconButton(tooltip: 'Laporan PDF', onPressed: () => exportReport(context, b, selected),
          icon: const Icon(Icons.picture_as_pdf_outlined)), const SizedBox(width: 8)],
        toolbarHeight: 68,
      ),
      body: SafeArea(child: Column(children: [
        if (tab < 4) monthPicker(),
        Expanded(child: switch(tab) {
          0 => dashboard(), 1 => transactionsPage(), 2 => billsPage(),
          3 => plansPage(), _ => settingsPage(),
        }),
      ])),
      bottomNavigationBar: NavigationBar(
        height: 76, selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.grid_view_rounded), selectedIcon: Icon(Icons.dashboard_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.swap_horiz_rounded), label: 'Rekod'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Bil'),
          NavigationDestination(icon: Icon(Icons.flag_outlined), label: 'Bajet'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Lain'),
        ],
      ),
    ),
  );
  Widget monthPicker() => Padding(
    padding: const EdgeInsets.fromLTRB(18, 0, 18, 9),
    child: Row(children: [
      IconButton(onPressed: () => changeMonth(-1), icon: const Icon(Icons.chevron_left)),
      Expanded(child: Center(child: Text(monthFormatter.format(selected), style: const TextStyle(fontWeight: FontWeight.w700)))),
      IconButton(onPressed: () => changeMonth(1), icon: const Icon(Icons.chevron_right)),
    ]),
  );
  Widget padded(List<Widget> content) => ListView(padding: const EdgeInsets.fromLTRB(18, 5, 18, 28), children: content);
  Widget white({required Widget child, EdgeInsetsGeometry padding = const EdgeInsets.all(18)}) => Container(
    padding: padding, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: child);
  Widget header(String title, {Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 11),
    child: Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))), if(action != null) action]));
  Widget pill(String label, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: .09), borderRadius: BorderRadius.circular(99)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)));

  Widget dashboard() {
    final unpaid = b.bills.where((e) => b.payment(e, selected) == null).toList();
    final today = DateTime.now();
    final overdue = unpaid.where((e) => today.isAfter(dueDate(e, selected).add(const Duration(days: 3)))).toList();
    final recent = b.txFor(selected).take(4).toList();
    return padded([
      Container(padding: const EdgeInsets.all(23), decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('BAKI BULAN INI', style: TextStyle(fontSize: 11, color: Colors.white70, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          Text(money.format(b.balance(selected)), style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 17),
          Row(children: [Expanded(child: miniMetric('Pendapatan', b.incomes(selected), const Color(0xFFB1E9D8))),
            Expanded(child: miniMetric('Perbelanjaan', b.expenses(selected) + b.paidBills(selected), Colors.white)),
            Expanded(child: miniMetric('Disimpan', b.saving(selected), Colors.white70))]),
        ])),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: quick('Tambah gaji', Icons.add_circle_outline, () => editTransaction(kind: 'income'))),
        const SizedBox(width: 9),
        Expanded(child: quick('Rekod belanja', Icons.shopping_bag_outlined, () => editTransaction(kind: 'expense'))),
      ]),
      if (overdue.isNotEmpty) ...[
        const SizedBox(height: 15),
        Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: const Color(0xFFFFF0ED), borderRadius: BorderRadius.circular(15)),
          child: Row(children: [const Icon(Icons.notifications_active_outlined, color: danger), const SizedBox(width: 11),
            Expanded(child: Text('${overdue.length} bil lewat lebih 3 hari. Semak status bayaran.', style: const TextStyle(color: danger, fontSize: 13, fontWeight: FontWeight.w600))),
            TextButton(onPressed: () => setState(() => tab = 2), child: const Text('Semak'))])),
      ],
      header('Bil belum dibayar', action: TextButton(onPressed: () => setState(() => tab = 2), child: const Text('Lihat semua'))),
      if (unpaid.isEmpty) white(child: const Text('Semua bil bulan ini sudah selesai. Hebat!', style: TextStyle(color: muted))),
      for (final bill in unpaid.take(3)) ...[
        white(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10), child: Row(children: [
          const Icon(Icons.receipt_long_outlined, color: ink), const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${bill['title']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('Akhir: ${dt.format(dueDate(bill, selected))}', style: const TextStyle(color: muted, fontSize: 12)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money.format(numv(bill['amount'])), style: const TextStyle(fontWeight: FontWeight.w800)),
            pill('Belum bayar', danger),
          ])])), const SizedBox(height: 8),
      ],
      header('Transaksi terkini', action: TextButton(onPressed: () => setState(() => tab = 1), child: const Text('Lihat semua'))),
      if (recent.isEmpty) white(child: const Text('Belum ada rekod. Tambah transaksi pertama anda.', style: TextStyle(color: muted))),
      for (final tx in recent) ...[transactionTile(tx), const SizedBox(height: 8)],
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: () => exportReport(context, b, selected),
        icon: const Icon(Icons.file_download_outlined), label: const Text('Muat turun laporan bulanan')),
    ]);
  }
  Widget miniMetric(String label, double value, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)), const SizedBox(height: 4),
    FittedBox(alignment: Alignment.centerLeft, fit: BoxFit.scaleDown,
      child: Text(money.format(value), style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800))),
  ]);
  Widget quick(String label, IconData icon, VoidCallback action) => Material(
    color: Colors.white, borderRadius: BorderRadius.circular(15),
    child: InkWell(borderRadius: BorderRadius.circular(15), onTap: action,
      child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [Icon(icon, color: accent), const SizedBox(width: 7),
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)))]))));

  Widget transactionTile(Map<String, dynamic> tx) {
    final kind = '${tx['kind']}';
    final isIncome = kind == 'income';
    return white(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(backgroundColor: isIncome ? const Color(0xFFE4F5EE) : const Color(0xFFF1F2F4),
        child: Icon(isIncome ? Icons.arrow_downward : kind == 'saving' ? Icons.savings_outlined : Icons.arrow_upward,
          color: isIncome ? accent : ink, size: 20)),
      title: Text('${tx['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('${dt.format(parseDate(tx['date']))} • ${tx['category'] ?? 'Lain-lain'}', style: const TextStyle(fontSize: 11)),
      trailing: Text('${isIncome ? '+' : '-'}${money.format(numv(tx['amount']))}',
        style: TextStyle(fontWeight: FontWeight.w800, color: isIncome ? accent : ink, fontSize: 12)),
      onTap: () => editTransaction(existing: tx),
    ));
  }
  Widget transactionsPage() {
    final txs = b.txFor(selected);
    return padded([
      Row(children: [
        Expanded(child: quick('Tambah pendapatan', Icons.add, () => editTransaction(kind: 'income'))),
        const SizedBox(width: 8),
        Expanded(child: quick('Tambah belanja', Icons.remove, () => editTransaction(kind: 'expense'))),
      ]),
      header('Sejarah transaksi (${txs.length})'),
      if (txs.isEmpty) white(child: const Text('Tiada transaksi bagi bulan ini.', style: TextStyle(color: muted))),
      for (final tx in txs) ...[transactionTile(tx), const SizedBox(height: 8)],
    ]);
  }

  Widget billsPage() {
    final sorted = [...b.bills]..sort((a,c) => (a['dueDay'] as num).compareTo(c['dueDay'] as num));
    final paid = sorted.where((x) => b.payment(x, selected) != null).length;
    return padded([
      Row(children: [Expanded(child: white(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Bil selesai', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 5), Text('$paid / ${sorted.length}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
      ]))), const SizedBox(width: 10),
      Expanded(child: white(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Komitmen bulanan', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 5), Text(money.format(sorted.fold(0.0, (s, e) => s + numv(e['amount']))),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      ])))]),
      header('Senarai bil', action: TextButton.icon(onPressed: () => editBill(), icon: const Icon(Icons.add), label: const Text('Tambah bil'))),
      if (sorted.isEmpty) white(child: const Text('Tambah bil berulang seperti elektrik, internet atau sewa.', style: TextStyle(color: muted))),
      for (final bill in sorted) ...[
        white(child: Column(children: [
          Row(children: [
            Checkbox(value: b.payment(bill, selected) != null, activeColor: accent, onChanged: (v) async {
              if (v == true) { await markPayment(bill); }
              else { await unpayBill(bill); }
            }),
            Expanded(child: InkWell(onTap: () => editBill(existing: bill), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${bill['title']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text('Jatuh tempo: ${dt.format(dueDate(bill, selected))}', style: const TextStyle(color: muted, fontSize: 12)),
            ]))),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money.format(numv(bill['amount'])), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              pill(b.payment(bill, selected) == null ? 'BELUM BAYAR' : 'SUDAH BAYAR',
                b.payment(bill, selected) == null ? danger : accent),
            ]),
          ]),
          if (b.payment(bill, selected) != null) ...[
            const Divider(height: 16),
            Row(children: [
              Expanded(child: Text('Dibayar: ${dt.format(parseDate(b.payment(bill, selected)!['paidDate']))}',
                style: const TextStyle(color: muted, fontSize: 12))),
              if ('${b.payment(bill, selected)!['receipt'] ?? ''}'.isNotEmpty)
                TextButton.icon(onPressed: () => openReceipt('${b.payment(bill, selected)!['receipt']}'),
                  icon: const Icon(Icons.attach_file, size: 16), label: const Text('Resit')),
              TextButton(onPressed: () => markPayment(bill), child: const Text('Edit')),
            ]),
          ],
        ])), const SizedBox(height: 9),
      ],
    ]);
  }

  Widget plansPage() {
    return padded([
      header('Bajet kategori', action: TextButton.icon(onPressed: () => editBudget(),
        icon: const Icon(Icons.edit_outlined), label: const Text('Tetapkan'))),
      if (!categories.any((c) => numv(b.budgets['${monthKey(selected)}_$c']) > 0))
        white(child: const Text('Belum tetapkan bajet. Contohnya RM300 untuk makanan.', style: TextStyle(color: muted))),
      for (final c in categories)
        if (numv(b.budgets['${monthKey(selected)}_$c']) > 0) ...[
          white(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(c, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text('${money.format(b.categorySpent(selected, c))} / ${money.format(numv(b.budgets['${monthKey(selected)}_$c']))}',
                style: const TextStyle(color: muted, fontSize: 11))]),
            const SizedBox(height: 10),
            ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(
              value: min(1.0, b.categorySpent(selected, c) / numv(b.budgets['${monthKey(selected)}_$c'])),
              minHeight: 8, backgroundColor: const Color(0xFFEDF0F2),
              valueColor: AlwaysStoppedAnimation<Color>(b.categorySpent(selected, c) > numv(b.budgets['${monthKey(selected)}_$c']) ? danger : accent))),
          ])), const SizedBox(height: 8),
        ],
      header('Tabung simpanan', action: TextButton.icon(onPressed: () => addGoal(),
        icon: const Icon(Icons.add), label: const Text('Tabung baru'))),
      if (b.goals.isEmpty) white(child: const Text('Bina tabung seperti Dana Kecemasan atau Laptop.', style: TextStyle(color: muted))),
      for (final goal in b.goals) ...[
        white(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text('${goal['name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
            IconButton(onPressed: () => deleteGoal(goal), icon: const Icon(Icons.more_horiz))]),
          Text('${money.format(b.goalSaved('${goal['id']}'))} / ${money.format(numv(goal['target']))}',
            style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: (b.goalSaved('${goal['id']}') / max(1.0, numv(goal['target']))).clamp(0.0,1.0),
            backgroundColor: const Color(0xFFECEFF1), color: accent, minHeight: 8, borderRadius: BorderRadius.circular(20)),
          const SizedBox(height: 9),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(
            onPressed: () => addSaving(goal), icon: const Icon(Icons.add), label: const Text('Tambah simpanan'))),
        ])), const SizedBox(height: 8),
      ],
    ]);
  }

  Widget settingsPage() => padded([
    white(child: Column(children: [
      SwitchListTile(contentPadding: EdgeInsets.zero, value: b.alerts,
        title: const Text('Notifikasi bil tertunggak', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text('Pilih peringatan 3 hari, 5 hari atau kedua-duanya selepas tarikh akhir.'),
        onChanged: (v) async { await b.setAlerts(v); if (v && !b.alerts) snack('Benarkan notifikasi dalam tetapan Android.'); }),
      const Divider(),
      DropdownButtonFormField<String>(
        value: b.reminderDays.length == 2 ? 'both' : '${b.reminderDays.first}',
        decoration: const InputDecoration(labelText: 'Peringatan selepas lewat'),
        items: const [
          DropdownMenuItem(value: '3', child: Text('3 hari')),
          DropdownMenuItem(value: '5', child: Text('5 hari')),
          DropdownMenuItem(value: 'both', child: Text('3 dan 5 hari')),
        ],
        onChanged: (v) async {
          b.reminderDays = v == '3' ? [3] : v == '5' ? [5] : [3, 5];
          await b.save();
        }),
      const SizedBox(height: 12),
      const Divider(),
      ListTile(contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.notifications_active_outlined, color: accent),
        title: const Text('Auto Track notifikasi bank', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text('Pilih aplikasi, kesan transaksi dan semak sebelum simpan.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AutoTrackPage(book: b))),
      ),
      const Divider(),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.file_download_outlined),
        title: const Text('Laporan PDF bulanan'), subtitle: const Text('Jana dan simpan/kongsi melalui Android'),
        onTap: () => exportReport(context, b, selected)),
      const Divider(),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.cloud_upload_outlined),
        title: const Text('Backup data & resit'),
        subtitle: const Text('Simpan fail JSON ke Drive atau fail peribadi'),
        onTap: () async { try { await b.exportBackup(); } catch (_) { snack('Gagal eksport backup.'); } }),
      const Divider(),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.restore_outlined),
        title: const Text('Pulihkan daripada backup'),
        subtitle: const Text('Gantikan data semasa dengan fail JSON backup'),
        onTap: () async {
          if (!await confirm('Pulihkan backup?', 'Data semasa akan diganti. Buat backup dahulu sebelum meneruskan.')) return;
          try { final success = await b.importBackup(); if (success) snack('Data dan resit berjaya dipulihkan.'); }
          catch (_) { snack('Backup tidak sah atau tidak dapat dipulihkan.'); }
        }),
    ])),
    const SizedBox(height: 13),
    white(child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Bagaimana data disimpan?', style: TextStyle(fontWeight: FontWeight.w800)),
      SizedBox(height: 9),
      Text('Semua rekod disimpan pada telefon ini. Resit disalin ke simpanan aplikasi. Tiada akaun atau sambungan internet diperlukan.',
        style: TextStyle(color: muted, height: 1.5)),
      SizedBox(height: 10),
      Text('Penting: memadam aplikasi biasanya memadam rekod dan resit. Gunakan Backup data & resit dan simpan failnya di lokasi peribadi.',
        style: TextStyle(color: danger, height: 1.4)),
    ])),
    const SizedBox(height: 14),
    Center(child: Text('DompetKu • Versi 2.1 (Auto Track)', style: TextStyle(color: muted, fontSize: 12))),
  ]);

  Future<DateTime?> datePick(DateTime initial) async => showDatePicker(
    context: context, initialDate: initial, firstDate: DateTime(2020), lastDate: DateTime(2100),
    locale: const Locale('en', 'US'));
  Future<void> editTransaction({String kind = 'income', Map<String, dynamic>? existing}) async {
    var type = existing?['kind'] == 'expense' ? 'expense' : kind;
    if (existing?['kind'] == 'saving') return;
    final title = TextEditingController(text: '${existing?['title'] ?? (type == 'income' ? 'Gaji' : '')}');
    final amount = TextEditingController(text: existing?['amount']?.toString() ?? '');
    final note = TextEditingController(text: '${existing?['note'] ?? ''}');
    var date = existing == null ? DateTime.now() : parseDate(existing['date']);
    var category = '${existing?['category'] ?? (type == 'income' ? 'Gaji' : 'Makanan')}';
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => sheet(ctx, 'Rekod transaksi', [
        SegmentedButton<String>(segments: const [
          ButtonSegment(value: 'income', label: Text('Pendapatan')),
          ButtonSegment(value: 'expense', label: Text('Perbelanjaan'))],
          selected: {type}, onSelectionChanged: (v) => update(() {
            type = v.first;
            category = type == 'income' ? 'Gaji' : 'Makanan';
          })),
        const SizedBox(height: 15), field(title, 'Tajuk', hint: 'Contoh: Gaji Oktober'),
        field(amount, 'Jumlah (RM)', number: true),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(value: category,
          decoration: const InputDecoration(labelText: 'Kategori'),
          items: (type == 'income' ? ['Gaji', 'Elaun', 'Bonus', 'Jualan', 'Lain-lain'] : categories)
            .map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
          onChanged: (v) => update(() => category = v!)),
        const SizedBox(height: 12),
        OutlinedButton.icon(icon: const Icon(Icons.calendar_month_outlined),
          onPressed: () async { final d = await datePick(date); if (d != null) update(() => date = d); },
          label: Text('Tarikh transaksi: ${dt.format(date)}')),
        field(note, 'Nota (pilihan)', hint: 'Maklumat tambahan'),
        Row(children: [
          if (existing != null) IconButton(onPressed: () async { b.transactions.removeWhere((x) => x['id'] == existing['id']); await b.save(); if (ctx.mounted) Navigator.pop(ctx); },
            icon: const Icon(Icons.delete_outline, color: danger)),
          Expanded(child: FilledButton(onPressed: () async {
            final sum = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
            if (title.text.trim().isEmpty || sum <= 0) { snack('Masukkan tajuk dan jumlah yang sah.'); return; }
            final record = {'id': existing?['id'] ?? uid(), 'kind': type, 'title': title.text.trim(),
              'amount': sum, 'category': category, 'date': iso(date), 'note': note.text.trim()};
            b.transactions.removeWhere((x) => x['id'] == record['id']); b.transactions.add(record);
            await b.save(); if (ctx.mounted) Navigator.pop(ctx);
          }, child: const Text('Simpan transaksi'))),
        ]),
      ])));
  }

  Future<void> editBill({Map<String, dynamic>? existing}) async {
    final title = TextEditingController(text: '${existing?['title'] ?? ''}');
    final amount = TextEditingController(text: existing?['amount']?.toString() ?? '');
    var day = (existing?['dueDay'] as num?)?.toInt() ?? 15;
    var category = '${existing?['category'] ?? 'Bil'}';
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => sheet(ctx, existing == null ? 'Tambah bil bulanan' : 'Edit bil', [
        field(title, 'Nama bil', hint: 'Contoh: Bil elektrik'),
        field(amount, 'Jumlah bil (RM)', number: true),
        DropdownButtonFormField<int>(value: day, decoration: const InputDecoration(labelText: 'Tarikh akhir setiap bulan'),
          items: List.generate(31, (i) => DropdownMenuItem(value: i + 1, child: Text('Hari ke-${i + 1}'))),
          onChanged: (v) => update(() => day = v!)),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: category, decoration: const InputDecoration(labelText: 'Kategori'),
          items: categories.map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
          onChanged: (v) => update(() => category = v!)),
        const SizedBox(height: 16),
        Row(children: [
          if (existing != null) IconButton(onPressed: () async {
            final confirmed = await confirm('Padam bil?', 'Rekod pembayaran lama akan kekal dalam sejarah laporan, tetapi bil ini tiada lagi dalam senarai.');
            if (!confirmed) return;
            b.bills.removeWhere((x) => x['id'] == existing['id']); await b.save(); if (ctx.mounted) Navigator.pop(ctx);
          }, icon: const Icon(Icons.delete_outline, color: danger)),
          Expanded(child: FilledButton(onPressed: () async {
            final sum = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
            if (title.text.trim().isEmpty || sum <= 0) { snack('Lengkapkan nama dan jumlah bil.'); return; }
            final record = {'id': existing?['id'] ?? uid(), 'title': title.text.trim(),
              'amount': sum, 'dueDay': day, 'category': category};
            b.bills.removeWhere((x) => x['id'] == record['id']); b.bills.add(record);
            await b.save(); if (ctx.mounted) Navigator.pop(ctx);
          }, child: const Text('Simpan bil'))),
        ]),
      ])));
  }

  Future<void> markPayment(Map<String, dynamic> bill) async {
    final current = b.payment(bill, selected);
    var paidDate = current == null ? DateTime.now() : parseDate(current['paidDate']);
    var receipt = '${current?['receipt'] ?? ''}';
    final amount = TextEditingController(text: '${current?['amount'] ?? bill['amount']}');
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => sheet(ctx, 'Sahkan bayaran bil', [
        Text('${bill['title']} • ${monthFormatter.format(selected)}', style: const TextStyle(color: muted)),
        const SizedBox(height: 9), field(amount, 'Jumlah sebenar dibayar (RM)', number: true),
        OutlinedButton.icon(icon: const Icon(Icons.calendar_today_outlined),
          onPressed: () async { final d = await datePick(paidDate); if (d != null) update(() => paidDate = d); },
          label: Text('Tarikh dibayar: ${dt.format(paidDate)}')),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.upload_file_outlined),
          onPressed: () async {
            try { final path = await b.captureReceipt(); if (path != null) update(() => receipt = path); }
            catch (_) { snack('Resit tidak dapat dibuka. Cuba fail JPG, PNG atau PDF.'); }
          }, label: Text(receipt.isEmpty ? 'Upload resit (JPG/PNG/PDF)' : 'Tukar resit terlampir')),
        if (receipt.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: Row(children: [const Icon(Icons.check_circle, color: accent, size: 17), const SizedBox(width: 8),
            Expanded(child: Text(receipt.split('/').last, style: const TextStyle(fontSize: 12))),
            IconButton(onPressed: () => update(() => receipt = ''), icon: const Icon(Icons.close, size: 18))])),
        const SizedBox(height: 13),
        FilledButton.icon(onPressed: () async {
          final sum = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
          if (sum <= 0) { snack('Jumlah bayaran mesti lebih daripada RM0.'); return; }
          b.payments[b.paymentId(bill, selected)] = {
            'billId': bill['id'], 'title': bill['title'], 'amount': sum,
            'category': bill['category'], 'month': monthKey(selected),
            'paidDate': iso(paidDate), 'receipt': receipt,
          };
          await b.save(); if (ctx.mounted) Navigator.pop(ctx); snack('Bil ditanda telah dibayar.');
        }, icon: const Icon(Icons.check_circle_outline), label: const Text('Sahkan sudah bayar')),
      ])));
  }
  Future<void> unpayBill(Map<String, dynamic> bill) async {
    if (!await confirm('Batalkan status bayaran?', 'Bil akan kembali kepada status belum bayar untuk bulan ini.')) return;
    b.payments.remove(b.paymentId(bill, selected)); await b.save();
  }
  Future<void> openReceipt(String path) async {
    if (!await File(path).exists()) { snack('Fail resit tidak ditemui pada telefon.'); return; }
    await OpenFilex.open(path);
  }
  Future<bool> confirm(String title, String body) async => await showDialog<bool>(context: context,
    builder: (c) => AlertDialog(title: Text(title), content: Text(body), actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Teruskan')),
    ])) ?? false;

  Future<void> editBudget() async {
    var c = 'Makanan';
    final amount = TextEditingController(text: '${b.budgets['${monthKey(selected)}_$c'] ?? ''}');
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => sheet(ctx, 'Tetapkan bajet', [
        Text('Untuk ${monthFormatter.format(selected)}', style: const TextStyle(color: muted)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(value: c, decoration: const InputDecoration(labelText: 'Kategori'),
          items: categories.map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
          onChanged: (v) => update(() { c = v!; amount.text = '${b.budgets['${monthKey(selected)}_$c'] ?? ''}'; })),
        field(amount, 'Had bajet (RM)', number: true),
        FilledButton(onPressed: () async {
          final val = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
          if (val < 0) { snack('Bajet mesti positif.'); return; }
          if (val == 0) { b.budgets.remove('${monthKey(selected)}_$c'); }
          else { b.budgets['${monthKey(selected)}_$c'] = val; }
          await b.save(); if (ctx.mounted) Navigator.pop(ctx);
        }, child: const Text('Simpan bajet')),
      ])));
  }
  Future<void> addGoal() async {
    final name = TextEditingController(); final target = TextEditingController();
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      builder: (ctx) => sheet(ctx, 'Tabung baru', [
        field(name, 'Nama tabung', hint: 'Contoh: Dana kecemasan'), field(target, 'Sasaran (RM)', number: true),
        FilledButton(onPressed: () async {
          final sum = double.tryParse(target.text.replaceAll(',', '.')) ?? 0;
          if (sum <= 0 || name.text.trim().isEmpty) { snack('Nama dan sasaran diperlukan.'); return; }
          b.goals.add({'id': uid(), 'name': name.text.trim(), 'target': sum});
          await b.save(); if (ctx.mounted) Navigator.pop(ctx);
        }, child: const Text('Cipta tabung')),
      ]));
  }
  Future<void> addSaving(Map<String, dynamic> goal) async {
    final amount = TextEditingController(); var date = DateTime.now();
    await showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) => sheet(ctx, 'Tambah simpanan', [
        Text('${goal['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        field(amount, 'Jumlah simpan (RM)', number: true),
        OutlinedButton.icon(onPressed: () async { final d = await datePick(date); if (d != null) update(() => date = d); },
          icon: const Icon(Icons.date_range), label: Text(dt.format(date))),
        FilledButton(onPressed: () async {
          final sum = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
          if (sum <= 0) { snack('Masukkan jumlah lebih RM0.'); return; }
          b.transactions.add({'id': uid(), 'kind': 'saving', 'title': 'Simpanan: ${goal['name']}',
            'goalId': goal['id'], 'amount': sum, 'date': iso(date), 'category': 'Simpanan'});
          await b.save(); if (ctx.mounted) Navigator.pop(ctx);
        }, child: const Text('Rekod simpanan')),
      ])));
  }
  Future<void> deleteGoal(Map<String, dynamic> goal) async {
    if (!await confirm('Padam tabung?', 'Rekod simpanan lama tidak akan dipadam daripada transaksi.')) return;
    b.goals.removeWhere((x) => x['id'] == goal['id']); await b.save();
  }
  Widget field(TextEditingController control, String label, {String? hint, bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: control,
      keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
      decoration: InputDecoration(labelText: label, hintText: hint)));
  Widget sheet(BuildContext ctx, String title, List<Widget> children) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
    child: SafeArea(top: false, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
          IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close))]),
        const SizedBox(height: 18), ...children,
      ]))));
}

Future<void> exportReport(BuildContext context, Book book, DateTime month) async {
  try {
    final key = monthKey(month);
    final transactions = book.txFor(month);
    final billsPaid = book.payments.values.map(asMap)
      .where((p) => '${p['paidDate']}'.startsWith(key)).toList();
    final billDue = book.bills;
    final pdf = pw.Document();
    pw.Widget metric(String label, double value) => pw.Container(
      padding: const pw.EdgeInsets.all(12), decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300)),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 5), pw.Text(money.format(value), style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
      ]));
    pw.Widget table(String title, List<List<String>> data) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(height: 17), pw.Text(title, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 8),
        if (data.length <= 1) pw.Text('Tiada rekod.', style: const pw.TextStyle(color: PdfColors.grey600))
        else pw.TableHelper.fromTextArray(headers: data.first, data: data.skip(1).toList(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8), cellPadding: const pw.EdgeInsets.all(6),
          border: pw.TableBorder.all(color: PdfColors.grey300, width: .4)),
      ]);
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(35),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('DOMPETKU • Laporan peribadi', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
        pw.Text('Halaman ${ctx.pageNumber}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ]),
      build: (ctx) => [
        pw.Text('DOMPETKU', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, letterSpacing: 2)),
        pw.SizedBox(height: 10),
        pw.Text('Laporan Kewangan Bulanan', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
        pw.Text(monthFormatter.format(month), style: const pw.TextStyle(color: PdfColors.grey600)),
        pw.SizedBox(height: 19),
        pw.Row(children: [pw.Expanded(child: metric('Pendapatan', book.incomes(month))), pw.SizedBox(width: 8),
          pw.Expanded(child: metric('Perbelanjaan + bil', book.expenses(month) + book.paidBills(month)))]),
        pw.SizedBox(height: 8),
        pw.Row(children: [pw.Expanded(child: metric('Simpanan', book.saving(month))), pw.SizedBox(width: 8),
          pw.Expanded(child: metric('Baki bulan ini', book.balance(month)))]),
        table('Senarai transaksi', [
          ['Tarikh', 'Jenis', 'Butiran', 'Kategori', 'Jumlah (RM)'],
          ...transactions.map((t) => [
            '${t['date']}', '${t['kind']}', '${t['title']}', '${t['category']}', money.format(numv(t['amount']))]),
        ]),
        table('Bil yang dibayar dalam bulan ini', [
          ['Tarikh bayaran', 'Bil', 'Bulan bil', 'Jumlah (RM)', 'Resit'],
          ...billsPaid.map((p) => [
            '${p['paidDate']}', '${p['title']}', '${p['month']}', money.format(numv(p['amount'])),
            '${p['receipt'] ?? ''}'.isEmpty ? 'Tiada' : 'Dilampirkan dalam aplikasi']),
        ]),
        table('Status bil bagi bulan dipilih', [
          ['Bil', 'Tarikh akhir', 'Jumlah (RM)', 'Status'],
          ...billDue.map((bill) => [
            '${bill['title']}', iso(dueDate(bill, month)), money.format(numv(bill['amount'])),
            book.payment(bill, month) != null ? 'Dibayar' : 'Belum dibayar']),
        ]),
        table('Bajet kategori', [
          ['Kategori', 'Bajet (RM)', 'Digunakan (RM)', 'Baki (RM)'],
          ...categories.where((c) => numv(book.budgets['${key}_$c']) > 0).map((c) {
            final limit = numv(book.budgets['${key}_$c']);
            final used = book.categorySpent(month, c);
            return [c, money.format(limit), money.format(used), money.format(limit - used)];
          }),
        ]),
        pw.SizedBox(height: 17),
        pw.Text('Nota: Baki = pendapatan - perbelanjaan - bil dibayar - simpanan. Resit tidak disertakan dalam fail PDF ini.',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      ],
    ));
    final bytes = await pdf.save();
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/Laporan_DompetKu_$key.pdf');
    await file.writeAsBytes(bytes);
    await Printing.sharePdf(bytes: bytes, filename: 'Laporan_DompetKu_$key.pdf');
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Laporan gagal dijana: $e')));
  }
}


/// Native Android notification access; only selected apps are analysed on-device.
class AutoTrackNative {
  static const _channel = MethodChannel('com.dompetku.notification_tracker');
  static Future<List<Map<String, dynamic>>> apps() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listApps') ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
  static Future<void> addCustomApp(String packageId, String name) async {
    await _channel.invokeMethod<void>('addCustomApp', {
      'package': packageId,
      'name': name,
    });
  }
  static Future<void> removeCustomApp(String packageId) async {
    await _channel.invokeMethod<void>('removeCustomApp', {'package': packageId});
  }
  static Future<Set<String>> selected() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getSelected') ?? [];
    return raw.map((e) => '$e').toSet();
  }
  static Future<void> select(Set<String> values) async {
    await _channel.invokeMethod<void>('setSelected', values.toList());
  }
  static Future<bool> enabled() async =>
      await _channel.invokeMethod<bool>('accessEnabled') ?? false;
  static Future<void> openSettings() async {
    await _channel.invokeMethod<void>('openAccessSettings');
  }
  static Future<List<Map<String, dynamic>>> pending() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getPending') ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
  static Future<void> consume(List<String> ids) async {
    await _channel.invokeMethod<void>('consume', ids);
  }
}

class AutoTrackPage extends StatefulWidget {
  final Book book;
  const AutoTrackPage({required this.book, super.key});
  @override
  State<AutoTrackPage> createState() => _AutoTrackPageState();
}

class _AutoTrackPageState extends State<AutoTrackPage> with WidgetsBindingObserver {
  List<Map<String, dynamic>> apps = [];
  List<Map<String, dynamic>> pending = [];
  Set<String> selected = {};
  bool enabled = false;
  bool loading = true;
  bool busy = false;
  String search = '';
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final results = await Future.wait([
        AutoTrackNative.apps(),
        AutoTrackNative.selected(),
        AutoTrackNative.enabled(),
        AutoTrackNative.pending(),
      ]).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() {
        apps = results[0] as List<Map<String, dynamic>>;
        selected = results[1] as Set<String>;
        enabled = results[2] as bool;
        pending = results[3] as List<Map<String, dynamic>>;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        loading = false;
        error = 'Gagal membaca tetapan Android: $e';
      });
    }
  }

  Future<void> _toggle(String package, bool value) async {
    final next = {...selected};
    if (value) { next.add(package); } else { next.remove(package); }
    try {
      await AutoTrackNative.select(next);
      if (mounted) setState(() => selected = next);
    } catch (_) {
      _message('Gagal menyimpan pilihan aplikasi.');
    }
  }

  Future<void> _addAppManually() async {
    final packageController = TextEditingController();
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    try {
      final details = await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Tambah aplikasi melalui ID'),
          content: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Jika aplikasi bank tidak muncul, masukkan ID pakej yang tepat. '
                  'Jangan masukkan ID secara teka-teki.',
                  style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Nama aplikasi',
                    hintText: 'Contoh: Bank saya'),
                maxLength: 60,
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Masukkan nama aplikasi' : null,
              ),
              TextFormField(
                controller: packageController,
                decoration: const InputDecoration(labelText: 'ID pakej Android',
                    hintText: 'Contoh: com.bsn.mybsn'),
                autocorrect: false,
                enableSuggestions: false,
                validator: (value) {
                  final id = (value ?? '').trim();
                  final valid = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$')
                      .hasMatch(id);
                  return valid ? null : 'ID pakej tidak sah';
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Batal')),
            FilledButton(onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(dialogContext, {
                'package': packageController.text.trim(),
                'name': nameController.text.trim(),
              });
            }, child: const Text('Tambah')),
          ],
        ),
      );
      if (details == null || !mounted) return;
      await AutoTrackNative.addCustomApp(details['package']!, details['name']!);
      await _reload();
      _message('Aplikasi ditambah. Aktifkan suis untuk mula menjejak.');
    } catch (_) {
      _message('Tidak berjaya menambah aplikasi. Semak ID pakej.');
    } finally {
      packageController.dispose();
      nameController.dispose();
    }
  }

  Future<void> _removeCustomApp(String packageId) async {
    try {
      await AutoTrackNative.removeCustomApp(packageId);
      await _reload();
      _message('Aplikasi manual dibuang daripada senarai.');
    } catch (_) {
      _message('Gagal membuang aplikasi.');
    }
  }

  void _message(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import(Map<String, dynamic> item, {bool ignore = false}) async {
    if (busy) return;
    setState(() => busy = true);
    final id = '${item['id'] ?? ''}';
    try {
      if (!ignore && id.isNotEmpty &&
          !widget.book.transactions.any((tx) => tx['notificationId'] == id)) {
        final date = DateTime.fromMillisecondsSinceEpoch(
          (item['timestamp'] as num).toInt());
        final kind = item['direction'] == 'income' ? 'income' : 'expense';
        final source = '${item['source'] ?? 'Bank'}';
        final detail = '${item['merchant'] ?? ''}'.trim();
        widget.book.transactions.add({
          'id': uid(),
          'kind': kind,
          'title': detail.isNotEmpty
              ? '$detail ($source)'
              : (kind == 'income' ? 'Duit diterima ($source)' : 'Bayaran ($source)'),
          'amount': numv(item['amount']),
          'date': iso(date),
          'category': 'Lain-lain',
          'notificationId': id,
          'source': 'notification',
        });
        await widget.book.save();
      }
      await AutoTrackNative.consume([id]);
      await _reload();
      _message(ignore ? 'Cadangan dibuang.' : 'Transaksi direkodkan. Boleh edit pada halaman Rekod.');
    } catch (_) {
      _message('Tidak berjaya menyimpan transaksi.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = apps.where((a) =>
      '${a['name']} ${a['package']}'.toLowerCase().contains(search.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Auto Track'), actions: [
        IconButton(onPressed: _reload, tooltip: 'Muat semula', icon: const Icon(Icons.refresh))
      ]),
      body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
          if (error != null) Card(child: Padding(padding: const EdgeInsets.all(16),
              child: Text(error!, style: const TextStyle(color: danger)))),
          Card(child: Padding(padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Jejak transaksi melalui notifikasi',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 9),
              const Text('DompetKu hanya memproses notifikasi daripada aplikasi yang kau pilih. '
                'Jumlah, jenis transaksi, aplikasi dan tarikh disimpan sebagai cadangan untuk disemak. '
                'OTP/TAC, mesej asal, baki akaun dan nombor akaun tidak disimpan.'),
              const SizedBox(height: 10),
              Text(enabled ? 'Akses notifikasi: AKTIF' : 'Akses notifikasi: BELUM DIBENARKAN',
                style: TextStyle(fontWeight: FontWeight.w800,
                  color: enabled ? accent : danger)),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: () async {
                try { await AutoTrackNative.openSettings(); }
                catch (_) { _message('Tak dapat buka tetapan Android.'); }
              }, icon: const Icon(Icons.settings),
                label: Text(enabled ? 'Urus kebenaran notifikasi' : 'Benarkan akses notifikasi')),
              const SizedBox(height: 8),
              const Text('Nota privasi: Android akan memberi kebenaran membaca notifikasi secara umum. '
                'DompetKu menapis mengikut aplikasi pilihan sebelum membaca kandungannya. '
                'Jangan pilih aplikasi sembang atau yang mengandungi OTP. Akses boleh ditutup bila-bila masa.',
                style: TextStyle(fontSize: 12, color: muted)),
            ]))),
          const SizedBox(height: 14),
          Text('Transaksi dikesan (${pending.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (pending.isEmpty)
            const Card(child: Padding(padding: EdgeInsets.all(16),
              child: Text('Belum ada transaksi dikesan. Notifikasi perlu menyebut jumlah RM dan bayaran atau duit masuk.'))),
          for (final item in pending.reversed) Card(child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(item['direction'] == 'income' ? Icons.arrow_downward : Icons.arrow_upward,
                  color: item['direction'] == 'income' ? accent : danger),
                const SizedBox(width: 8),
                Expanded(child: Text('${item['source'] ?? 'Bank'}',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(money.format(numv(item['amount'])),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 7),
              Text('${item['direction'] == 'income' ? 'Duit masuk' : 'Duit keluar'}'
                ' • ${dt.format(DateTime.fromMillisecondsSinceEpoch((item['timestamp'] as num).toInt()))}'),
              if ('${item['merchant'] ?? ''}'.trim().isNotEmpty)
                Text('Butiran: ${item['merchant']}', style: const TextStyle(color: muted)),
              const SizedBox(height: 9),
              Row(children: [
                OutlinedButton(onPressed: busy ? null : () => _import(item, ignore: true),
                  child: const Text('Abaikan')),
                const SizedBox(width: 10),
                FilledButton(onPressed: busy ? null : () => _import(item),
                  child: const Text('Simpan transaksi')),
              ]),
            ]))),
          const SizedBox(height: 15),
          Text('Aplikasi dipilih (${selected.length})',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Hanya notifikasi kewangan daripada aplikasi yang ditandakan akan diperiksa.',
            style: TextStyle(color: muted)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _addAppManually,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Aplikasi tiada? Tambah ID pakej manual'),
          ),
          const SizedBox(height: 8),
          const Text('myBSN dipaparkan secara khusus. Jika status "Belum dikesan", '
              'semak sama ada aplikasi bank sudah dipasang. Aplikasi lain boleh '
              'ditambah dengan ID pakej yang tepat.',
              style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 10),
          TextField(onChanged: (v) => setState(() => search = v),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
              hintText: 'Cari aplikasi bank / e-wallet')),
          const SizedBox(height: 10),
          if (filtered.isEmpty) const Padding(padding: EdgeInsets.all(12),
            child: Text('Tiada aplikasi dijumpai.')),
          for (final app in filtered) SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            title: Text('${app['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${app['package']}'
              '${app['installed'] == false ? ' • Belum dikesan' : ''}'
              '${app['manual'] == true ? ' • ID manual' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
            secondary: app['manual'] == true
                ? IconButton(
                    tooltip: 'Buang aplikasi manual',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeCustomApp('${app['package']}'),
                  )
                : null,
            value: selected.contains('${app['package']}'),
            onChanged: app['installed'] == false
                ? null
                : (v) => _toggle('${app['package']}', v),
          ),
          const SizedBox(height: 18),
          const Text('Kadar ketepatan berbeza mengikut format notifikasi setiap bank. '
            'Bukan sambungan ke akaun bank. Semak semua cadangan dengan rekod bank sebenar.',
            style: TextStyle(fontSize: 12, color: muted)),
        ]),
    );
  }
}
