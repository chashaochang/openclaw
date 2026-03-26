/**
 * Canvas host URL normalization (subset of Android GatewaySession logic).
 */
import { url } from '@kit.ArkTS';
import type { GatewayEndpoint } from './GatewayEndpoint';

interface ParsedHttpUrl {
  scheme: string;
  host: string;
  port: number;
  rest: string;
}

function isLoopbackHost(host: string): boolean {
  const h = host.trim().toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

function buildFallbackCanvasUrl(endpoint: GatewayEndpoint): string | null {
  const h = endpoint.host.trim();
  if (h.length === 0) {
    return null;
  }
  const scheme = endpoint.useTls ? 'https' : 'http';
  const hostPart = h.includes(':') && !h.startsWith('[') ? `[${h}]` : h;
  const defPort = endpoint.useTls ? 443 : 80;
  const portSuffix = endpoint.port === defPort ? '' : `:${endpoint.port}`;
  return `${scheme}://${hostPart}${portSuffix}/`;
}

function parseHttpParts(raw: string): ParsedHttpUrl | null {
  try {
    const u = url.URL.parseURL(raw);
    const host = (u.hostname ?? '').trim();
    if (host.length === 0) {
      return null;
    }
    const proto = (u.protocol ?? '').replace(':', '').toLowerCase();
    const scheme = proto === 'https' ? 'https' : proto === 'http' ? 'http' : '';
    if (scheme.length === 0) {
      return null;
    }
    const portRaw = u.port;
    const explicitPort = portRaw ? parseInt(portRaw, 10) : NaN;
    const port = Number.isFinite(explicitPort)
      ? explicitPort
      : scheme === 'https'
        ? 443
        : 80;
    const pathname = u.pathname ?? '';
    const search = u.search ?? '';
    const hash = u.hash ?? '';
    const combined = pathname + search + hash;
    const rest = combined.length > 0 ? combined : '/';
    const out: ParsedHttpUrl = { scheme, host, port, rest };
    return out;
  } catch {
    return null;
  }
}

export function normalizeCanvasHostUrl(
  raw: string | null | undefined,
  endpoint: GatewayEndpoint,
): string | null {
  const trimmed = (raw ?? '').trim();
  if (trimmed.length > 0) {
    const parts = parseHttpParts(trimmed);
    if (!parts) {
      return trimmed;
    }
    if (parts.host.length > 0 && !isLoopbackHost(parts.host) && endpoint.useTls) {
      if (parts.scheme !== 'https') {
        const defPort = 443;
        const portSuffix = endpoint.port === defPort ? '' : `:${endpoint.port}`;
        const pathPart = parts.rest.length > 0 ? parts.rest : '/';
        return `https://${parts.host.includes(':') ? `[${parts.host}]` : parts.host}${portSuffix}${pathPart}`;
      }
    }
    return trimmed;
  }
  return buildFallbackCanvasUrl(endpoint);
}

export function replaceCanvasCapabilityInScopedHostUrl(scopedUrl: string, capability: string): string | null {
  const marker = '/__openclaw__/cap/';
  const markerStart = scopedUrl.indexOf(marker);
  if (markerStart < 0) {
    return null;
  }
  const capabilityStart = markerStart + marker.length;
  const slashEnd = scopedUrl.indexOf('/', capabilityStart);
  const queryEnd = scopedUrl.indexOf('?', capabilityStart);
  const fragmentEnd = scopedUrl.indexOf('#', capabilityStart);
  const ends: number[] = [];
  if (slashEnd >= 0) {
    ends.push(slashEnd);
  }
  if (queryEnd >= 0) {
    ends.push(queryEnd);
  }
  if (fragmentEnd >= 0) {
    ends.push(fragmentEnd);
  }
  const capabilityEnd = ends.length > 0 ? Math.min(...ends) : scopedUrl.length;
  if (capabilityEnd <= capabilityStart) {
    return null;
  }
  return scopedUrl.substring(0, capabilityStart) + capability + scopedUrl.substring(capabilityEnd);
}
