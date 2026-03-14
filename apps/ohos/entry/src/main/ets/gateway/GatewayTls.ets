/**
 * TLS fingerprint utilities for gateway trust (TOFU).
 * v1: Store expected fingerprint per endpoint; full cert validation uses system default.
 */
import { SecurePrefs } from '../common/SecurePrefs';

const PREFIX = 'gateway.tls.fingerprint.';

function normalizeFingerprint(raw: string): string {
  const stripped = raw.trim()
    .replace(/^sha-?256\s*:?\s*/i, '');
  return stripped.toLowerCase().replace(/[^0-9a-f]/g, '');
}

export function normalizeFingerprintForDisplay(raw: string): string {
  return normalizeFingerprint(raw);
}

export async function getStoredFingerprint(prefs: SecurePrefs, stableId: string): Promise<string | null> {
  const key = PREFIX + stableId;
  const val = await prefs.getString(key);
  return val && val.length > 0 ? val : null;
}

export async function storeFingerprint(prefs: SecurePrefs, stableId: string, fingerprint: string): Promise<void> {
  const key = PREFIX + stableId;
  const normalized = normalizeFingerprint(fingerprint);
  await prefs.putString(key, normalized);
}

export async function clearStoredFingerprint(prefs: SecurePrefs, stableId: string): Promise<void> {
  const key = PREFIX + stableId;
  await prefs.remove(key);
}
