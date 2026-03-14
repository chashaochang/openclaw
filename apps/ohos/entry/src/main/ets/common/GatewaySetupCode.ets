/**
 * Gateway setup code: decode pairing QR/setup code, parse endpoint.
 * Format matches openclaw qr --setup-code-only (Base64 JSON: url, token?, password?).
 */
import { util, url } from '@kit.ArkTS';

export interface GatewayEndpointConfig {
  host: string;
  port: number;
  tls: boolean;
  displayUrl: string;
}

export interface GatewaySetupCode {
  url: string;
  token: string | null;
  password: string | null;
}

interface SetupCodeJson {
  url?: string;
  token?: string;
  password?: string;
}

interface WrappedSetupCodeJson {
  setupCode?: string;
}

function padBase64(input: string): string {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const remainder = normalized.length % 4;
  return remainder === 0 ? normalized : normalized + '='.repeat(4 - remainder);
}

function getStringField(obj: SetupCodeJson, key: 'url' | 'token' | 'password'): string | null {
  const v = key === 'url' ? obj.url : key === 'token' ? obj.token : obj.password;
  if (v == null) return null;
  const t = String(v).trim();
  return t.length > 0 ? t : null;
}

export function decodeGatewaySetupCode(rawInput: string): GatewaySetupCode | null {
  const trimmed = rawInput.trim();
  if (trimmed.length === 0) return null;
  try {
    const padded = padBase64(trimmed);
    const base64Helper = new util.Base64Helper();
    const bytes = base64Helper.decodeSync(padded);
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    const json = decoder.decodeToString(bytes);
    const parsed = JSON.parse(json) as SetupCodeJson;
    const urlVal = getStringField(parsed, 'url');
    if (!urlVal) return null;
    const token = getStringField(parsed, 'token');
    const password = getStringField(parsed, 'password');
    const out: GatewaySetupCode = { url: urlVal, token, password };
    return out;
  } catch {
    return null;
  }
}

export function parseGatewayEndpoint(rawInput: string): GatewayEndpointConfig | null {
  const raw = rawInput.trim();
  if (raw.length === 0) return null;
  const normalized = raw.includes('://') ? raw : 'https://' + raw;
  try {
    const urlObj = url.URL.parseURL(normalized);
    const host = (urlObj.hostname ?? '').trim();
    if (host.length === 0) return null;
    const scheme = (urlObj.protocol ?? '').replace(':', '').toLowerCase();
    const tls = scheme === 'wss' || scheme === 'https';
    const port = urlObj.port ? parseInt(urlObj.port, 10) : 18789;
    const portNum = (port >= 1 && port <= 65535) ? port : 18789;
    const displayUrl = (tls ? 'https' : 'http') + '://' + host + ':' + portNum;
    const cfg: GatewayEndpointConfig = { host, port: portNum, tls, displayUrl };
    return cfg;
  } catch {
    return null;
  }
}

export function resolveSetupCodeCandidate(rawInput: string): string | null {
  const trimmed = rawInput.trim();
  if (trimmed.length === 0) return null;
  try {
    const parsed = JSON.parse(trimmed) as WrappedSetupCodeJson;
    const setupCode = parsed.setupCode;
    const v = setupCode != null ? String(setupCode).trim() : '';
    const resolved = v.length > 0 ? v : null;
    return resolved ?? trimmed;
  } catch {
    return trimmed;
  }
}

export function resolveScannedSetupCode(rawInput: string): string | null {
  const candidate = resolveSetupCodeCandidate(rawInput);
  if (!candidate) return null;
  return decodeGatewaySetupCode(candidate) ? candidate : null;
}

export function composeGatewayManualUrl(host: string, port: string, tls: boolean): string | null {
  const h = host.trim();
  const p = parseInt(port, 10);
  if (h.length === 0 || isNaN(p) || p < 1 || p > 65535) return null;
  const scheme = tls ? 'https' : 'http';
  return `${scheme}://${h}:${p}`;
}
