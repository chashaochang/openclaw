/**
 * Gateway TLS helpers: fingerprint pinning, cert probing, and local cert storage.
 */
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import socket from '@ohos.net.socket';
import cert from '@ohos.security.cert';
import fs from '@ohos.file.fs';
import { SecurePrefs } from '../common/SecurePrefs';

const FINGERPRINT_PREFIX = 'gateway.tls.fingerprint.';
const CERT_DIR_NAME = 'openclaw_gateway_tls';

export interface GatewayTlsProbeResult {
  fingerprintSha256: string;
  pem: string;
}

function normalizeFingerprint(raw: string): string {
  const stripped = raw.trim().replace(/^sha-?256\s*:?\s*/i, '');
  return stripped.toLowerCase().replace(/[^0-9a-f]/g, '');
}

function bytesToHex(data: Uint8Array): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < data.length; i++) {
    const b = data[i];
    out += hex.charAt((b >> 4) & 0x0f) + hex.charAt(b & 0x0f);
  }
  return out;
}

function sha256Hex(data: Uint8Array): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: data });
  return bytesToHex(md.digestSync().data);
}

function bytesToUtf8(data: Uint8Array): string {
  return new util.TextDecoder('utf-8', { fatal: false }).decodeWithStream(data, { stream: false });
}

function base64Encode(data: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(data);
}

function base64Decode(data: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(data);
}

function chunkString(input: string, size: number): string {
  let out = '';
  for (let i = 0; i < input.length; i += size) {
    if (out.length > 0) {
      out += '\n';
    }
    out += input.slice(i, i + size);
  }
  return out;
}

function pemToDerBytes(pem: string): Uint8Array {
  const normalized = pem
    .replace(/-----BEGIN CERTIFICATE-----/g, '')
    .replace(/-----END CERTIFICATE-----/g, '')
    .replace(/\s+/g, '');
  return base64Decode(normalized);
}

function encodingBlobToPem(blob: cert.EncodingBlob): string {
  if (blob.encodingFormat === cert.EncodingFormat.FORMAT_PEM) {
    const text = bytesToUtf8(blob.data).trim();
    return text.endsWith('\n') ? text : `${text}\n`;
  }
  const base64 = chunkString(base64Encode(blob.data), 64);
  return `-----BEGIN CERTIFICATE-----\n${base64}\n-----END CERTIFICATE-----\n`;
}

function encodingBlobToDerBytes(blob: cert.EncodingBlob): Uint8Array {
  if (blob.encodingFormat === cert.EncodingFormat.FORMAT_PEM) {
    return pemToDerBytes(bytesToUtf8(blob.data));
  }
  return blob.data;
}

function isIpv6Host(host: string): boolean {
  return host.includes(':');
}

function certFileNameForStableId(stableId: string): string {
  const sanitized = stableId.trim().replace(/[^a-zA-Z0-9._-]/g, '_');
  return `${sanitized || 'gateway'}.pem`;
}

function ensureCertDir(context: common.UIAbilityContext): string {
  const dir = `${context.filesDir}/${CERT_DIR_NAME}`;
  try {
    fs.accessSync(dir);
  } catch {
    fs.mkdirSync(dir, true);
  }
  return dir;
}

export function normalizeFingerprintForDisplay(raw: string): string {
  return normalizeFingerprint(raw);
}

export async function getStoredFingerprint(prefs: SecurePrefs, stableId: string): Promise<string | null> {
  const key = FINGERPRINT_PREFIX + stableId;
  const val = await prefs.getString(key);
  return val && val.length > 0 ? val : null;
}

export async function storeFingerprint(prefs: SecurePrefs, stableId: string, fingerprint: string): Promise<void> {
  const key = FINGERPRINT_PREFIX + stableId;
  await prefs.putString(key, normalizeFingerprint(fingerprint));
}

export async function clearStoredFingerprint(prefs: SecurePrefs, stableId: string): Promise<void> {
  const key = FINGERPRINT_PREFIX + stableId;
  await prefs.remove(key);
}

export function getTrustedCertPath(context: common.UIAbilityContext, stableId: string): string {
  return `${ensureCertDir(context)}/${certFileNameForStableId(stableId)}`;
}

export function hasTrustedCertPath(context: common.UIAbilityContext, stableId: string): boolean {
  try {
    fs.accessSync(getTrustedCertPath(context, stableId));
    return true;
  } catch {
    return false;
  }
}

export function writeTrustedCertPem(
  context: common.UIAbilityContext,
  stableId: string,
  pem: string,
): string {
  const fullPath = getTrustedCertPath(context, stableId);
  const opened = fs.openSync(fullPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    const bytes = new util.TextEncoder().encodeInto(pem);
    fs.writeSync(opened.fd, bytes);
  } finally {
    fs.closeSync(opened);
  }
  return fullPath;
}

export function clearTrustedCertPath(context: common.UIAbilityContext, stableId: string): void {
  const fullPath = getTrustedCertPath(context, stableId);
  try {
    fs.unlinkSync(fullPath);
  } catch {
    // Best-effort cleanup only.
  }
}

export async function probeGatewayTlsCertificate(
  host: string,
  port: number,
  timeoutMs: number = 3000,
): Promise<GatewayTlsProbeResult | null> {
  const trimmedHost = host.trim();
  if (trimmedHost.length === 0 || port < 1 || port > 65535) {
    return null;
  }

  const tlsSocket = socket.constructTLSSocketInstance();
  try {
    await tlsSocket.connect({
      address: {
        address: trimmedHost,
        port,
        family: isIpv6Host(trimmedHost) ? 2 : 1,
      },
      secureOptions: {},
      skipRemoteValidation: true,
      timeout: timeoutMs,
    });
    const remoteCert = await tlsSocket.getRemoteCertificate();
    if (!remoteCert || remoteCert.data.length === 0) {
      return null;
    }
    const x509 = await cert.createX509Cert(remoteCert);
    const encoded = await x509.getEncoded();
    const derBytes = encodingBlobToDerBytes(encoded);
    const pem = encodingBlobToPem(encoded);
    return {
      fingerprintSha256: sha256Hex(derBytes),
      pem,
    };
  } catch {
    return null;
  } finally {
    try {
      await tlsSocket.close();
    } catch {
      // ignore
    }
  }
}
