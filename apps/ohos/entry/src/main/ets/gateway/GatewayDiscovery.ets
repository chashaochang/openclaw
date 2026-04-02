import { common } from '@kit.AbilityKit';
import mdns from '@ohos.net.mdns';

const OPENCLAW_GATEWAY_SERVICE_TYPE = '_openclaw-gw._tcp.';
const DISCOVERY_STATUS_SEARCHING = 'Searching for gateways…';
const DISCOVERY_STATUS_UNAVAILABLE = 'Gateway discovery unavailable';

export interface GatewayEndpointInfo {
  name: string;
  host: string;
  port: number;
  useTls: boolean;
  stableId: string;
}

export function createManualEndpoint(host: string, port: number, useTls: boolean): GatewayEndpointInfo {
  const stableId = `manual-${host}-${port}-${useTls}`;
  return { name: host.trim(), host: host.trim(), port, useTls, stableId };
}

export type GatewayDiscoveryListener = (
  endpoints: GatewayEndpointInfo[],
  statusText: string,
) => void;

export class GatewayDiscovery {
  private context: common.UIAbilityContext;
  private discoveryService: mdns.DiscoveryService | null = null;
  private endpointsById: Map<string, GatewayEndpointInfo> = new Map();
  private listener: GatewayDiscoveryListener | null = null;
  private statusText: string = DISCOVERY_STATUS_SEARCHING;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  start(listener: GatewayDiscoveryListener): void {
    this.listener = listener;
    if (this.discoveryService !== null) {
      this.publish();
      return;
    }
    this.statusText = DISCOVERY_STATUS_SEARCHING;
    this.endpointsById.clear();
    this.publish();
    try {
      const service = mdns.createDiscoveryService(this.context, OPENCLAW_GATEWAY_SERVICE_TYPE);
      this.discoveryService = service;
      service.on('discoveryStart', this.onDiscoveryStart);
      service.on('discoveryStop', this.onDiscoveryStop);
      service.on('serviceFound', this.onServiceFound);
      service.on('serviceLost', this.onServiceLost);
      service.startSearchingMDNS();
    } catch {
      this.statusText = DISCOVERY_STATUS_UNAVAILABLE;
      this.publish();
    }
  }

  stop(): void {
    const service = this.discoveryService;
    if (service !== null) {
      try {
        service.off('discoveryStart', this.onDiscoveryStart);
        service.off('discoveryStop', this.onDiscoveryStop);
        service.off('serviceFound', this.onServiceFound);
        service.off('serviceLost', this.onServiceLost);
        service.stopSearchingMDNS();
      } catch {
        // Best-effort cleanup only.
      }
    }
    this.discoveryService = null;
    this.listener = null;
    this.endpointsById.clear();
    this.statusText = DISCOVERY_STATUS_SEARCHING;
  }

  private readonly onDiscoveryStart = (): void => {
    this.statusText = DISCOVERY_STATUS_SEARCHING;
    this.publish();
  };

  private readonly onDiscoveryStop = (): void => {
    this.publish();
  };

  private readonly onServiceFound = (serviceInfo: mdns.LocalServiceInfo): void => {
    void this.resolveAndStore(serviceInfo);
  };

  private readonly onServiceLost = (serviceInfo: mdns.LocalServiceInfo): void => {
    const stableId = this.stableIdForServiceName(serviceInfo.serviceName);
    this.endpointsById.delete(stableId);
    this.publish();
  };

  private async resolveAndStore(serviceInfo: mdns.LocalServiceInfo): Promise<void> {
    let resolved = serviceInfo;
    try {
      resolved = await mdns.resolveLocalService(this.context, serviceInfo);
    } catch {
      // Fall back to the unresolved payload when the resolve call times out.
    }
    const endpoint = this.endpointFromServiceInfo(resolved);
    if (endpoint === null) {
      return;
    }
    this.endpointsById.set(endpoint.stableId, endpoint);
    this.publish();
  }

  private endpointFromServiceInfo(serviceInfo: mdns.LocalServiceInfo): GatewayEndpointInfo | null {
    const host = serviceInfo.host?.address?.trim() ?? '';
    const basePort = typeof serviceInfo.port === 'number' ? serviceInfo.port : 0;
    const attrs = this.decodeServiceAttributes(serviceInfo.serviceAttribute);
    const resolvedPort = this.parseIntAttr(attrs['gatewayPort']) ?? basePort;
    if (host.length === 0 || resolvedPort <= 0) {
      return null;
    }
    const serviceName = this.normalizeServiceName(serviceInfo.serviceName);
    const name = (attrs['displayName'] ?? serviceName).trim() || host;
    return {
      name,
      host,
      port: resolvedPort,
      useTls: this.parseBoolAttr(attrs['gatewayTls']),
      stableId: this.stableIdForServiceName(serviceName),
    };
  }

  private decodeServiceAttributes(
    attrs: Array<mdns.ServiceAttribute> | undefined,
  ): Record<string, string> {
    const decoded: Record<string, string> = {};
    if (!attrs) {
      return decoded;
    }
    for (let i = 0; i < attrs.length; i++) {
      const item = attrs[i];
      const key = (item.key ?? '').trim();
      if (key.length === 0) {
        continue;
      }
      decoded[key] = this.decodeBytes(item.value);
    }
    return decoded;
  }

  private decodeBytes(value: Array<number> | undefined): string {
    if (!value || value.length === 0) {
      return '';
    }
    let out = '';
    for (let i = 0; i < value.length; i++) {
      out += String.fromCharCode(value[i]);
    }
    return out.trim();
  }

  private parseIntAttr(raw: string | undefined): number | null {
    const parsed = parseInt((raw ?? '').trim(), 10);
    return Number.isFinite(parsed) ? parsed : null;
  }

  private parseBoolAttr(raw: string | undefined): boolean {
    const normalized = (raw ?? '').trim().toLowerCase();
    return normalized === '1' || normalized === 'true' || normalized === 'yes';
  }

  private normalizeServiceName(raw: string): string {
    return (raw ?? '').trim().replace(/\.+$/, '');
  }

  private stableIdForServiceName(serviceName: string): string {
    return `${OPENCLAW_GATEWAY_SERVICE_TYPE}|local.|${this.normalizeServiceName(serviceName)}`;
  }

  private buildStatusText(): string {
    const count = this.endpointsById.size;
    if (count <= 0) {
      return DISCOVERY_STATUS_SEARCHING;
    }
    if (count === 1) {
      return '1 gateway found';
    }
    return `${count} gateways found`;
  }

  private publish(): void {
    const listener = this.listener;
    if (listener === null) {
      return;
    }
    const endpoints = Array.from(this.endpointsById.values())
      .sort((a, b) => a.name.localeCompare(b.name));
    listener(endpoints, endpoints.length > 0 ? this.buildStatusText() : this.statusText);
  }
}
