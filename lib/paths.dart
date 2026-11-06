import 'package:path/path.dart' as p;

/// Joins a zip entry name onto [base] and returns the normalised path, or
/// null when the entry would land outside [base] (absolute or `..` paths).
String? safeJoin(String base, String entry) {
  final ctx = p.posix;
  if (entry.isEmpty || ctx.isAbsolute(entry)) return null;
  final root = ctx.normalize(base);
  final out = ctx.normalize(ctx.join(root, entry));
  return ctx.isWithin(root, out) ? out : null;
}
