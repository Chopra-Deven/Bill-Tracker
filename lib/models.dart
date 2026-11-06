// Data model for Bill Tracker. Everything is stored as one JSON document.

class FileRef {
  String name;
  String path; // absolute path on the phone

  FileRef(this.name, this.path);

  bool get isPdf => name.toLowerCase().endsWith('.pdf');

  Map<String, dynamic> toJson() => {'name': name, 'path': path};
  static FileRef? fromJson(dynamic j) =>
      j == null ? null : FileRef(j['name'] ?? 'file', j['path'] ?? '');
}

class Cycle {
  bool paid;
  double? amount;
  String? paidOn; // yyyy-mm-dd
  String via;
  FileRef? receipt;
  FileRef? statement;
  int snoozes;
  int snoozedUntil; // epoch ms
  bool dismissed;

  Cycle({
    this.paid = false,
    this.amount,
    this.paidOn,
    this.via = '',
    this.receipt,
    this.statement,
    this.snoozes = 0,
    this.snoozedUntil = 0,
    this.dismissed = false,
  });

  Map<String, dynamic> toJson() => {
        'paid': paid,
        'amount': amount,
        'paidOn': paidOn,
        'via': via,
        'receipt': receipt?.toJson(),
        'statement': statement?.toJson(),
        'snoozes': snoozes,
        'snoozedUntil': snoozedUntil,
        'dismissed': dismissed,
      };

  factory Cycle.fromJson(Map<String, dynamic> j) => Cycle(
        paid: j['paid'] == true,
        amount: (j['amount'] as num?)?.toDouble(),
        paidOn: j['paidOn'],
        via: j['via'] ?? '',
        receipt: FileRef.fromJson(j['receipt']),
        statement: FileRef.fromJson(j['statement']),
        snoozes: (j['snoozes'] as num?)?.toInt() ?? 0,
        snoozedUntil: (j['snoozedUntil'] as num?)?.toInt() ?? 0,
        dismissed: j['dismissed'] == true,
      );
}

class ReminderCfg {
  bool on;
  int before; // days before due date
  String time; // HH:mm
  int snooze; // minutes
  int maxSnooze;
  bool requireReceipt;

  ReminderCfg({
    this.on = true,
    this.before = 5,
    this.time = '09:00',
    this.snooze = 60,
    this.maxSnooze = 3,
    this.requireReceipt = true,
  });

  int get hour => int.tryParse(time.split(':')[0]) ?? 9;
  int get minute => int.tryParse(time.split(':').length > 1 ? time.split(':')[1] : '0') ?? 0;

  Map<String, dynamic> toJson() => {
        'on': on,
        'before': before,
        'time': time,
        'snooze': snooze,
        'maxSnooze': maxSnooze,
        'requireReceipt': requireReceipt,
      };

  factory ReminderCfg.fromJson(Map<String, dynamic>? j) {
    if (j == null) return ReminderCfg();
    return ReminderCfg(
      on: j['on'] != false,
      before: (j['before'] as num?)?.toInt() ?? 5,
      time: j['time'] ?? '09:00',
      snooze: (j['snooze'] as num?)?.toInt() ?? 60,
      maxSnooze: (j['maxSnooze'] as num?)?.toInt() ?? 3,
      requireReceipt: j['requireReceipt'] != false,
    );
  }

  ReminderCfg copy() => ReminderCfg.fromJson(toJson());
}

class Bill {
  String id;
  int nid; // numeric id used for notification ids
  String category; // 'card' | 'utility'
  String name;
  String desc;
  int dueDay;
  int? stmtDay;
  double? limit;
  String via;
  String startKey; // yyyy-mm of the first bill
  Map<String, Cycle> cycles;
  ReminderCfg rem;

  Bill({
    required this.id,
    required this.nid,
    this.category = 'card',
    required this.name,
    this.desc = '',
    required this.dueDay,
    this.stmtDay,
    this.limit,
    this.via = '',
    required this.startKey,
    Map<String, Cycle>? cycles,
    ReminderCfg? rem,
  })  : cycles = cycles ?? {},
        rem = rem ?? ReminderCfg();

  bool get isCard => category == 'card';

  Map<String, dynamic> toJson() => {
        'id': id,
        'nid': nid,
        'category': category,
        'name': name,
        'desc': desc,
        'dueDay': dueDay,
        'stmtDay': stmtDay,
        'limit': limit,
        'via': via,
        'startKey': startKey,
        'cycles': cycles.map((k, v) => MapEntry(k, v.toJson())),
        'rem': rem.toJson(),
      };

  factory Bill.fromJson(Map<String, dynamic> j) => Bill(
        id: j['id'],
        nid: (j['nid'] as num?)?.toInt() ?? 1,
        category: j['category'] ?? 'card',
        name: j['name'] ?? '',
        desc: j['desc'] ?? '',
        dueDay: (j['dueDay'] as num?)?.toInt() ?? 1,
        stmtDay: (j['stmtDay'] as num?)?.toInt(),
        limit: (j['limit'] as num?)?.toDouble(),
        via: j['via'] ?? '',
        startKey: j['startKey'] ?? '2026-01',
        cycles: ((j['cycles'] as Map?) ?? {}).map(
            (k, v) => MapEntry(k as String, Cycle.fromJson(Map<String, dynamic>.from(v)))),
        rem: ReminderCfg.fromJson(j['rem'] == null ? null : Map<String, dynamic>.from(j['rem'])),
      );
}

class AppSettings {
  bool lockOn;
  int lockAfter; // minutes
  bool autoBackup;
  String backupFreq; // daily | weekly | monthly
  bool backupFiles;
  int lastBackup; // epoch ms

  AppSettings({
    this.lockOn = false,
    this.lockAfter = 1,
    this.autoBackup = false,
    this.backupFreq = 'weekly',
    this.backupFiles = true,
    this.lastBackup = 0,
  });

  Map<String, dynamic> toJson() => {
        'lockOn': lockOn,
        'lockAfter': lockAfter,
        'autoBackup': autoBackup,
        'backupFreq': backupFreq,
        'backupFiles': backupFiles,
        'lastBackup': lastBackup,
      };

  factory AppSettings.fromJson(Map<String, dynamic>? j) {
    if (j == null) return AppSettings();
    return AppSettings(
      lockOn: j['lockOn'] == true,
      lockAfter: (j['lockAfter'] as num?)?.toInt() ?? 1,
      autoBackup: j['autoBackup'] == true,
      backupFreq: j['backupFreq'] ?? 'weekly',
      backupFiles: j['backupFiles'] != false,
      lastBackup: (j['lastBackup'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The signed-in user, shown on the Profile screen. Synced to Drive.
class Profile {
  String name;
  String email;
  String photoUrl;

  Profile({this.name = '', this.email = '', this.photoUrl = ''});

  Map<String, dynamic> toJson() => {'name': name, 'email': email, 'photoUrl': photoUrl};

  static Profile fromJson(Map? j) => j == null
      ? Profile()
      : Profile(name: j['name'] ?? '', email: j['email'] ?? '', photoUrl: j['photoUrl'] ?? '');
}

/// Sync state of this phone. Never uploaded.
class SyncSession {
  String accountId; // Google account id that owns this phone's data
  String email;
  bool firstSyncDone;
  int baseRev; // Drive data rev this phone last matched
  bool pending; // local changes not yet in Drive
  bool conflict; // phone and Drive both changed; user must choose
  int lastSyncAt; // epoch ms of the last successful sync
  List<String> pendingDeletes; // relative paths to delete from Drive

  SyncSession({
    this.accountId = '',
    this.email = '',
    this.firstSyncDone = false,
    this.baseRev = 0,
    this.pending = false,
    this.conflict = false,
    this.lastSyncAt = 0,
    List<String>? pendingDeletes,
  }) : pendingDeletes = pendingDeletes ?? [];

  bool get signedIn => accountId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'email': email,
        'firstSyncDone': firstSyncDone,
        'baseRev': baseRev,
        'pending': pending,
        'conflict': conflict,
        'lastSyncAt': lastSyncAt,
        'pendingDeletes': pendingDeletes,
      };

  static SyncSession fromJson(Map? j) {
    if (j == null) return SyncSession();
    return SyncSession(
      accountId: j['accountId'] ?? '',
      email: j['email'] ?? '',
      firstSyncDone: j['firstSyncDone'] == true,
      baseRev: (j['baseRev'] as num?)?.toInt() ?? 0,
      pending: j['pending'] == true,
      conflict: j['conflict'] == true,
      lastSyncAt: (j['lastSyncAt'] as num?)?.toInt() ?? 0,
      pendingDeletes: ((j['pendingDeletes'] as List?) ?? []).map((e) => '$e').toList(),
    );
  }
}

class AppData {
  List<Bill> bills;
  AppSettings settings;
  int nextNid;
  Profile profile;
  SyncSession session;
  int rev; // revision of the data, raised on every upload to Drive

  /// Relative paths of receipts and statements the user deleted. Synced, so
  /// other phones delete them too and never upload them again.
  List<String> deleted;

  AppData(
      {List<Bill>? bills,
      AppSettings? settings,
      this.nextNid = 1,
      Profile? profile,
      SyncSession? session,
      this.rev = 0,
      List<String>? deleted})
      : bills = bills ?? [],
        deleted = deleted ?? [],
        settings = settings ?? AppSettings(),
        profile = profile ?? Profile(),
        session = session ?? SyncSession();

  Map<String, dynamic> toJson() => {
        'app': 'BillTracker',
        'version': 1,
        'nextNid': nextNid,
        'rev': rev,
        'deleted': deleted,
        'settings': settings.toJson(),
        'profile': profile.toJson(),
        'session': session.toJson(),
        'bills': bills.map((b) => b.toJson()).toList(),
      };

  /// What goes to Drive: no per-phone settings or sync state, and file paths
  /// converted by [toRel] (absolute on the phone → relative in Drive).
  Map<String, dynamic> toCloudJson(String Function(String absPath) toRel) {
    final j = toJson()
      ..remove('settings')
      ..remove('session');
    for (final b in (j['bills'] as List)) {
      for (final c in (b['cycles'] as Map).values) {
        for (final k in ['receipt', 'statement']) {
          final f = c[k];
          if (f != null) c[k] = {...f, 'path': toRel(f['path'] as String)};
        }
      }
    }
    return j;
  }

  /// Builds data downloaded from Drive. [toAbs] turns a relative path into a
  /// path on this phone, or null when it is unsafe (that file ref is dropped).
  /// This phone's [keepSettings] and [keepSession] are kept.
  static AppData fromCloudJson(Map<String, dynamic> j, String? Function(String rel) toAbs, AppSettings keepSettings,
      SyncSession keepSession) {
    final d = AppData.fromJson(j);
    for (final b in d.bills) {
      for (final c in b.cycles.values) {
        FileRef? fix(FileRef? f) {
          if (f == null) return null;
          final abs = toAbs(f.path);
          return abs == null ? null : (f..path = abs);
        }

        c.receipt = fix(c.receipt);
        c.statement = fix(c.statement);
      }
    }
    d.settings = keepSettings;
    d.session = keepSession;
    return d;
  }

  factory AppData.fromJson(Map<String, dynamic> j) {
    final bills = ((j['bills'] as List?) ?? [])
        .map((e) => Bill.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    var next = (j['nextNid'] as num?)?.toInt() ?? 1;
    for (final b in bills) {
      if (b.nid >= next) next = b.nid + 1;
    }
    return AppData(
      bills: bills,
      settings: AppSettings.fromJson(
          j['settings'] == null ? null : Map<String, dynamic>.from(j['settings'])),
      nextNid: next,
      profile: Profile.fromJson(j['profile'] as Map?),
      session: SyncSession.fromJson(j['session'] as Map?),
      rev: (j['rev'] as num?)?.toInt() ?? 0,
      deleted: ((j['deleted'] as List?) ?? []).map((e) => '$e').toList(),
    );
  }
}
