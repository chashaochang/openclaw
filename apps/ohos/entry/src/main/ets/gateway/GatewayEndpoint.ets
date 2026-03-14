/**
 * Gateway endpoint descriptor (host, port, TLS).
 */
export interface GatewayEndpoint {
  host: string;
  port: number;
  useTls: boolean;
}

export function buildWsUrl(endpoint: GatewayEndpoint): string {
  const scheme = endpoint.useTls ? 'wss' : 'ws';
  const host = endpoint.host.includes(':') ? `[${endpoint.host}]` : endpoint.host;
  return `${scheme}://${host}:${endpoint.port}`;
}
