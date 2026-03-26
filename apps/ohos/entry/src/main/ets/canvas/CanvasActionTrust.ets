/**
 * Trust model for A2UI postMessage from Web (matches Android CanvasActionTrust).
 */
import { url } from '@kit.ArkTS';

interface ParsedTrustUrl {
  scheme: string;
  host: string;
  port: number;
  path: string;
}

function parseHttpParts(raw: string): ParsedTrustUrl | null {
  try {
    const u = url.URL.parseURL(raw);
    const host = (u.hostname ?? '').trim();
    if (host.length === 0) {
      return null;
    }
    const proto = (u.protocol ?? '').replace(':', '').toLowerCase();
    const scheme = proto;
    const portRaw = u.port;
    const explicitPort = portRaw ? parseInt(portRaw, 10) : NaN;
    const defaultPort = scheme === 'https' ? 443 : scheme === 'http' ? 80 : NaN;
    const port = Number.isFinite(explicitPort) ? explicitPort : defaultPort;
    if (!Number.isFinite(port)) {
      return null;
    }
    let path = u.pathname ?? '';
    if (path.length === 0) {
      path = '/';
    }
    const out: ParsedTrustUrl = { scheme, host, port, path };
    return out;
  } catch {
    return null;
  }
}

function isTrustedA2uiPage(candidateRaw: string, trustedUrl: string): boolean {
  const candidate = parseHttpParts(candidateRaw);
  const trusted = parseHttpParts(trustedUrl);
  if (!candidate || !trusted) {
    return false;
  }
  if (candidate.scheme !== trusted.scheme) {
    return false;
  }
  if (candidate.host.toLowerCase() !== trusted.host.toLowerCase()) {
    return false;
  }
  if (candidate.port !== trusted.port) {
    return false;
  }
  const trustedPath = trusted.path.length > 0 ? trusted.path : '/';
  const candidatePath = candidate.path.length > 0 ? candidate.path : '/';
  const trustedPrefix = trustedPath.endsWith('/') ? trustedPath : `${trustedPath}/`;
  return candidatePath === trustedPath || candidatePath.startsWith(trustedPrefix);
}

export function isHarmonyScaffoldUrl(candidate: string): boolean {
  const c = candidate.trim().toLowerCase();
  return c.includes('canvasscaffold/scaffold.html') && c.startsWith('resource://');
}

export function isTrustedCanvasActionUrl(rawUrl: string | null | undefined, trustedA2uiUrls: string[]): boolean {
  const candidate = (rawUrl ?? '').trim();
  if (candidate.length === 0) {
    return false;
  }
  if (isHarmonyScaffoldUrl(candidate)) {
    return true;
  }
  const parts = parseHttpParts(candidate);
  if (!parts) {
    return false;
  }
  if (parts.scheme === 'file') {
    return false;
  }
  return trustedA2uiUrls.some((t) => isTrustedA2uiPage(candidate, t));
}
