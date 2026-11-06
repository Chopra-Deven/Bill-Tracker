import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models.dart';
import '../sync/sync_service.dart';
import 'common.dart';
import 'lock.dart';

const docExts = ['jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf'];

/// Lets the user pick an image or PDF. Returns (path, name).
Future<(String, String)?> pickDoc() async {
  final r = await LockService.outside(
      () => FilePicker.pickFiles(type: FileType.custom, allowedExtensions: docExts));
  if (r.isEmpty || r.first.path == null) return null;
  final f = r.first;
  return (f.path!, f.name);
}

/// Picks a backup .zip. Returns its path.
Future<String?> pickDocAny() async {
  final r = await LockService.outside(
      () => FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']));
  return r.isEmpty ? null : r.first.path;
}

Future<void> openFile(BuildContext context, FileRef f) async {
  if (!await File(f.path).exists()) {
    if (context.mounted) {
      toast(
          context,
          SyncService.ready && SyncService.I.downloadingFiles
              ? 'Still downloading from Google Drive. Try again in a moment.'
              : 'File not found. It may have been moved or deleted.');
    }
    return;
  }
  final r = await LockService.outside(() => OpenFilex.open(f.path));
  if (r.type != ResultType.done && context.mounted) {
    toast(context, 'No app on this phone can open this file.');
  }
}

bool isImagePath(String p) => RegExp(r'\.(jpe?g|png|webp|heic)$', caseSensitive: false).hasMatch(p);

class FileThumb extends StatelessWidget {
  final String? path;
  final double size;
  final IconData empty;
  const FileThumb(this.path, {super.key, this.size = 44, this.empty = Icons.remove});
  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    Widget child;
    if (path == null) {
      child = Icon(empty, size: 18, color: p.muted);
    } else if (isImagePath(path!) && File(path!).existsSync()) {
      child = Image.file(File(path!), fit: BoxFit.cover, width: size, height: size, cacheWidth: (size * 3).round());
    } else {
      child = Text(path!.toLowerCase().endsWith('.pdf') ? 'PDF' : 'FILE',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: p.muted));
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}
