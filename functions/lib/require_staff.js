/**
 * Shared auth guard for every staff callable.
 *
 * `request.auth` alone is not enough: anonymous sign-in is enabled on this
 * project and the public web API key ships in every client, so anyone can
 * mint an anonymous token in one unauthenticated HTTP call. The Admin SDK
 * calls inside these functions bypass firestore.rules, so each callable must
 * apply the same "real account, not anonymous" test the rules' signedIn()
 * does. clmgpx is the only client that signs in anonymously and it calls no
 * callables.
 */

const { HttpsError } = require("firebase-functions/v2/https");

/** True when [token] (decoded ID token or `request.auth.token`) is anonymous. */
function isAnonymousToken(token) {
  return token?.firebase?.sign_in_provider === "anonymous";
}

/** Throws `unauthenticated` unless [auth] is a signed-in, non-anonymous user. */
function requireStaff(auth, message = "Staff sign-in required.") {
  if (!auth || isAnonymousToken(auth.token)) {
    throw new HttpsError("unauthenticated", message);
  }
}

module.exports = { requireStaff, isAnonymousToken };
