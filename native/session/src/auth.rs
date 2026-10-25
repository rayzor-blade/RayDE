//! Who may edit. A published session lets anyone look, and asks for a GitHub identity before the first change.
//! The sign-in itself happens at the edge (a Worker runs GitHub's OAuth); the session only verifies what the edge signed.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64URL};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    /// The GitHub login.
    pub login: String,
    /// The GitHub account id, which stays when the login is renamed.
    pub id: u64,
}

/// Decides whether a connection may change the workspace. A session without one lets every connection edit.
pub trait Authority: Send + Sync + 'static {
    /// Where a person signs in, for the client to open.
    fn login_url(&self) -> String;
    /// The identity a credential from the edge proves, if it is genuine and has not expired at `now` (seconds since the epoch).
    fn verify(&self, credential: &str, now: u64) -> Option<Identity>;
}

/// Credentials signed with a secret the edge and the session share: `base64url(payload).base64url(HMAC-SHA256(payload))`,
/// the payload being `{"login", "id", "exp"}` as JSON.
pub struct SignedCredentials {
    secret: Vec<u8>,
    login: String,
}

#[derive(Serialize, Deserialize)]
struct Claims {
    login: String,
    id: u64,
    exp: u64,
}

impl SignedCredentials {
    pub fn new(secret: impl Into<Vec<u8>>, login_url: impl Into<String>) -> Self {
        Self { secret: secret.into(), login: login_url.into() }
    }

    fn mac(&self, payload: &[u8]) -> Hmac<Sha256> {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.secret).expect("HMAC takes a key of any length");
        mac.update(payload);
        mac
    }

    /// What the edge does after GitHub has vouched for `identity`; here so the two sides cannot drift apart.
    pub fn issue(&self, identity: &Identity, expires: u64) -> String {
        let payload = serde_json::to_vec(&Claims { login: identity.login.clone(), id: identity.id, exp: expires }).unwrap();
        format!("{}.{}", B64URL.encode(&payload), B64URL.encode(self.mac(&payload).finalize().into_bytes()))
    }
}

impl Authority for SignedCredentials {
    fn login_url(&self) -> String {
        self.login.clone()
    }

    fn verify(&self, credential: &str, now: u64) -> Option<Identity> {
        let (payload, signature) = credential.split_once('.')?;
        let (payload, signature) = (B64URL.decode(payload).ok()?, B64URL.decode(signature).ok()?);
        // `verify_slice` compares in constant time.
        self.mac(&payload).verify_slice(&signature).ok()?;
        let claims: Claims = serde_json::from_slice(&payload).ok()?;
        (claims.exp > now && !claims.login.is_empty()).then_some(Identity { login: claims.login, id: claims.id })
    }
}
