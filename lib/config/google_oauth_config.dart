// config/google_oauth_config.dart
//
// The OAuth "Web application" client the app uses to ask a user's
// permission to create Gmail drafts (distribution reports with a real HTML
// table). Client ids are public by design; the secret never comes near the
// browser.
//
// Create it in Google Cloud Console → APIs & Services → Credentials for the
// clmschedule project, with the app's web origins as Authorized JavaScript
// origins. Set as the default below; --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID
// overrides it. Empty would make reports fall back to a plain-text Gmail
// draft link.
const String kGoogleOAuthWebClientId = String.fromEnvironment(
  'GOOGLE_OAUTH_WEB_CLIENT_ID',
  defaultValue:
      '346281153032-27tponlvammujmkv8olf59glge3e453v.apps.googleusercontent.com',
);
