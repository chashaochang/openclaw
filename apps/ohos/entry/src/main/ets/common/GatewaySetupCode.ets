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

export enum GatewayEndpointValidationError {
  INVALID_URL = 'INVALID_URL',
  INSECURE_REMOTE_URL = 'INSECURE_REMOTE_URL',
}

export interface GatewayEndpointParseResult {
  config: GatewayEndpointConfig | null;
  error: GatewayEndpointValidationError | null;
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

export interface GatewayScannedSetupCodeResult {
  setupCode: string | null;
  error: GatewayEndpointValidationError | null;
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
  return parseGatewayEndpointResult(rawInput).config;
}

function parseIpv4Segments(host: string): number[] | null {
  const parts = host.split('.');
  if (parts.length !== 4) {
    return null;
  }
  const out: number[] = [];
  for (const part of parts) {
    const value = parseInt(part, 10);
    if (isNaN(value) || value < 0 || value > 255) {
      return null;
    }
    out.push(value);
  }
  return out;
}

export function isLoopbackGatewayHost(host: string): boolean {
  let normalized = host.trim().toLowerCase().replace(/^\[/, '').replace(/\]$/, '');
  if (normalized.endsWith('.')) {
    normalized = normalized.slice(0, -1);
  }
  if (normalized.length === 0) {
    return false;
  }
  const zoneIndex = normalized.indexOf('%');
  if (zoneIndex >= 0) {
    return false;
  }
  if (normalized === 'localhost' || normalized === '::1') {
    return true;
  }
  const ipv4 = parseIpv4Segments(normalized);
  if (ipv4) {
    return ipv4[0] === 127;
  }
  if (normalized.startsWith('::ffff:')) {
    const mappedIpv4 = parseIpv4Segments(normalized.slice('::ffff:'.length));
    return mappedIpv4 !== null && mappedIpv4[0] === 127;
  }
  return false;
}

export function parseGatewayEndpointResult(rawInput: string): GatewayEndpointParseResult {
  const raw = rawInput.trim();
  if (raw.length === 0) {
    return { config: null, error: GatewayEndpointValidationError.INVALID_URL };
  }
  const normalized = raw.includes('://') ? raw : 'https://' + raw;
  try {
    const urlObj = url.URL.parseURL(normalized);
    const host = (urlObj.hostname ?? '').trim();
    if (host.length === 0) {
      return { config: null, error: GatewayEndpointValidationError.INVALID_URL };
    }
    const scheme = (urlObj.protocol ?? '').replace(':', '').toLowerCase();
    let tls = true;
    if (scheme === 'ws' || scheme === 'http') {
      tls = false;
    } else if (scheme === 'wss' || scheme === 'https' || scheme.length === 0) {
      tls = true;
    }
    if (!tls && !isLoopbackGatewayHost(host)) {
      return { config: null, error: GatewayEndpointValidationError.INSECURE_REMOTE_URL };
    }
    const defaultPort = tls ? 443 : 18789;
    const displayDefaultPort = tls ? 443 : 80;
    const port = urlObj.port ? parseInt(urlObj.port, 10) : defaultPort;
    const portNum = (port >= 1 && port <= 65535) ? port : defaultPort;
    const displayHost = host.includes(':') ? `[${host}]` : host;
    const displayUrl = portNum === displayDefaultPort && defaultPort === displayDefaultPort
      ? `${tls ? 'https' : 'http'}://${displayHost}`
      : `${tls ? 'https' : 'http'}://${displayHost}:${portNum}`;
    const cfg: GatewayEndpointConfig = { host, port: portNum, tls, displayUrl };
    return { config: cfg, error: null };
  } catch {
    return { config: null, error: GatewayEndpointValidationError.INVALID_URL };
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
  return resolveScannedSetupCodeResult(rawInput).setupCode;
}

export function resolveScannedSetupCodeResult(rawInput: string): GatewayScannedSetupCodeResult {
  const candidate = resolveSetupCodeCandidate(rawInput);
  if (!candidate) {
    return { setupCode: null, error: GatewayEndpointValidationError.INVALID_URL };
  }
  const decoded = decodeGatewaySetupCode(candidate);
  if (!decoded) {
    return { setupCode: null, error: GatewayEndpointValidationError.INVALID_URL };
  }
  const parsed = parseGatewayEndpointResult(decoded.url);
  if (parsed.config === null) {
    return { setupCode: null, error: parsed.error };
  }
  return { setupCode: candidate, error: null };
}

export function composeGatewayManualUrl(host: string, port: string, tls: boolean): string | null {
  const h = host.trim();
  const p = parseInt(port, 10);
  if (h.length === 0 || isNaN(p) || p < 1 || p > 65535) return null;
  const scheme = tls ? 'https' : 'http';
  return `${scheme}://${h}:${p}`;
}
