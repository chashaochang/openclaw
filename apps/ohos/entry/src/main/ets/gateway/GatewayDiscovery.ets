/**
 * Gateway discovery placeholder.
 * v1: No DNS-SD; manual URL entry only.
 */
export interface GatewayEndpointInfo {
  host: string;
  port: number;
  useTls: boolean;
  stableId: string;
}

export function createManualEndpoint(host: string, port: number, useTls: boolean): GatewayEndpointInfo {
  const stableId = `manual-${host}-${port}-${useTls}`;
  return { host: host.trim(), port, useTls, stableId };
}
