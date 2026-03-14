/**
 * Device auth payload for gateway connect (v3 format).
 */
function normalizeMetadataField(value: string | undefined): string {
  const trimmed = (value ?? '').trim();
  if (trimmed.length === 0) return '';
  let out = '';
  for (let i = 0; i < trimmed.length; i++) {
    const ch = trimmed[i];
    if (ch >= 'A' && ch <= 'Z') {
      out += String.fromCharCode(ch.charCodeAt(0) + 32);
    } else {
      out += ch;
    }
  }
  return out;
}

export function buildV3(
  deviceId: string,
  clientId: string,
  clientMode: string,
  role: string,
  scopes: string[],
  signedAtMs: number,
  token: string | null,
  nonce: string,
  platform: string | undefined,
  deviceFamily: string | undefined
): string {
  const scopeString = scopes.join(',');
  const authToken = token ?? '';
  const platformNorm = normalizeMetadataField(platform);
  const deviceFamilyNorm = normalizeMetadataField(deviceFamily);
  return [
    'v3',
    deviceId,
    clientId,
    clientMode,
    role,
    scopeString,
    String(signedAtMs),
    authToken,
    nonce,
    platformNorm,
    deviceFamilyNorm,
  ].join('|');
}
