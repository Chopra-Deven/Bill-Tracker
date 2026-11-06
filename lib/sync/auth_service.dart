import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google sign-in for Drive sync. Asks only for the Drive app-data scope.
/// The web OAuth client id comes from
/// `--dart-define=GOOGLE_SERVER_CLIENT_ID=<id>` (see docs/GOOGLE_SIGN_IN_SETUP.md).
class AuthService {
  AuthService._();
  static final AuthService I = AuthService._();

  static const scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  bool _inited = false;
  GoogleSignInAccount? _account;

  /// False when the app was built without a client id: sign-in cannot work.
  bool get configured => serverClientId.isNotEmpty;

  GoogleSignInAccount? get account => _account;

  Future<void> init() async {
    if (_inited || !configured) return;
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _inited = true;
  }

  /// Interactive sign-in plus Drive permission. Throws [AuthFailure].
  Future<GoogleSignInAccount> signIn() async {
    if (!configured) throw AuthFailure.notConfigured();
    try {
      await init();
      final a = await GoogleSignIn.instance.authenticate(scopeHint: const [scope]);
      await a.authorizationClient.authorizeScopes(const [scope]);
      _account = a;
      return a;
    } on GoogleSignInException catch (e) {
      throw AuthFailure.from(e);
    }
  }

  /// The previously signed-in account without asking the user, or null
  /// (offline, signed out, or the account was removed from the phone).
  Future<GoogleSignInAccount?> silent() async {
    if (_account != null) return _account;
    if (!configured) return null;
    try {
      await init();
      final f = GoogleSignIn.instance.attemptLightweightAuthentication();
      _account = f == null ? null : await f;
    } catch (e) {
      debugPrint('silent sign-in failed: $e');
      return null;
    }
    return _account;
  }

  /// Access token for the Drive scope. With [interactive] the user may be
  /// asked to grant access again (only from a button tap).
  Future<String?> token({bool interactive = false}) async {
    final a = await silent();
    if (a == null) return null;
    try {
      final z = await a.authorizationClient.authorizationForScopes(const [scope]) ??
          (interactive ? await a.authorizationClient.authorizeScopes(const [scope]) : null);
      return z?.accessToken;
    } on GoogleSignInException catch (e) {
      debugPrint('token failed: ${e.code}');
      return null;
    }
  }

  /// Drops a token Drive rejected, so the next [token] call gets a fresh one.
  Future<void> clearToken(String t) async {
    try {
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(accessToken: t);
    } catch (e) {
      debugPrint('clear token failed: $e');
    }
  }

  Future<void> signOut() async {
    _account = null;
    try {
      await init();
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('sign out failed: $e');
    }
  }
}

/// A sign-in that did not finish, with a message for the user.
class AuthFailure implements Exception {
  final String message;
  final bool cancelled;
  AuthFailure(this.message, {this.cancelled = false});

  factory AuthFailure.notConfigured() => AuthFailure(
      'Google sign-in is not set up in this build. See docs/GOOGLE_SIGN_IN_SETUP.md.');

  factory AuthFailure.from(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return AuthFailure('Sign-in was cancelled.', cancelled: true);
      case GoogleSignInExceptionCode.interrupted:
      case GoogleSignInExceptionCode.uiUnavailable:
        return AuthFailure('Sign-in was interrupted. Try again.');
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return AuthFailure('Google sign-in is not set up correctly for this app (${e.description ?? e.code.name}).');
      default:
        return AuthFailure('Could not sign in. Check the internet connection and try again.');
    }
  }

  @override
  String toString() => message;
}
