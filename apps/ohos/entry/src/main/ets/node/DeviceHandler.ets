/**
 * Device invoke handler: status, info, permissions, health.
 */
import { deviceInfo } from '@kit.BasicServicesKit';
import type { InvokeResult } from '../gateway/GatewaySession';

const APP_VERSION = '1.0.0';
const APP_BUILD = '1';

interface BatteryStatus {
  level: number;
  state: string;
  lowPowerModeEnabled: boolean;
}

interface ThermalStatus {
  state: string;
}

interface StorageStatus {
  totalBytes: number;
  freeBytes: number;
  usedBytes: number;
}

interface NetworkStatus {
  status: string;
  isExpensive: boolean;
  isConstrained: boolean;
  interfaces: string[];
}

interface StatusPayload {
  battery: BatteryStatus;
  thermal: ThermalStatus;
  storage: StorageStatus;
  network: NetworkStatus;
  uptimeSeconds: number;
}

interface InfoPayload {
  deviceName: string;
  modelIdentifier: string;
  systemName: string;
  systemVersion: string;
  appVersion: string;
  appBuild: string;
  locale: string;
}

interface PermissionEntry {
  status: string;
  promptable: boolean;
}

interface PermissionsPayload {
  permissions: Record<string, PermissionEntry>;
}

interface MemoryStatus {
  pressure: string;
  totalRamBytes: number;
  availableRamBytes: number;
  usedRamBytes: number;
  lowMemory: boolean;
}

interface BatteryHealth {
  state: string;
  chargingType: string;
}

interface PowerStatus {
  dozeModeEnabled: boolean;
  lowPowerModeEnabled: boolean;
}

interface HealthPayload {
  memory: MemoryStatus;
  battery: BatteryHealth;
  power: PowerStatus;
  system: Record<string, string>;
}

export class DeviceHandler {
  handleDeviceStatus(_paramsJson: string | null): InvokeResult {
    const r: InvokeResult = { ok: true, payloadJson: this.statusPayloadJson(), error: null };
    return r;
  }

  handleDeviceInfo(_paramsJson: string | null): InvokeResult {
    const r: InvokeResult = { ok: true, payloadJson: this.infoPayloadJson(), error: null };
    return r;
  }

  handleDevicePermissions(_paramsJson: string | null): InvokeResult {
    const r: InvokeResult = { ok: true, payloadJson: this.permissionsPayloadJson(), error: null };
    return r;
  }

  handleDeviceHealth(_paramsJson: string | null): InvokeResult {
    const r: InvokeResult = { ok: true, payloadJson: this.healthPayloadJson(), error: null };
    return r;
  }

  private statusPayloadJson(): string {
    const battery: BatteryStatus = { level: 1, state: 'unknown', lowPowerModeEnabled: false };
    const thermal: ThermalStatus = { state: 'nominal' };
    const storage: StorageStatus = { totalBytes: 0, freeBytes: 0, usedBytes: 0 };
    const network: NetworkStatus = { status: 'satisfied', isExpensive: false, isConstrained: false, interfaces: ['other'] };
    const payload: StatusPayload = { battery, thermal, storage, network, uptimeSeconds: 0 };
    return JSON.stringify(payload);
  }

  private infoPayloadJson(): string {
    const deviceName = deviceInfo.deviceType ?? 'HarmonyOS';
    const systemVersion = deviceInfo.osFullName ?? '';
    const payload: InfoPayload = {
      deviceName: deviceName,
      modelIdentifier: deviceName,
      systemName: 'HarmonyOS',
      systemVersion: systemVersion,
      appVersion: APP_VERSION,
      appBuild: APP_BUILD,
      locale: 'zh-CN',
    };
    return JSON.stringify(payload);
  }

  private permissionsPayloadJson(): string {
    const camera: PermissionEntry = { status: 'denied', promptable: true };
    const microphone: PermissionEntry = { status: 'denied', promptable: true };
    const location: PermissionEntry = { status: 'denied', promptable: true };
    const permissions: Record<string, PermissionEntry> = {};
    permissions['camera'] = camera;
    permissions['microphone'] = microphone;
    permissions['location'] = location;
    const payload: PermissionsPayload = { permissions };
    return JSON.stringify(payload);
  }

  private healthPayloadJson(): string {
    const memory: MemoryStatus = { pressure: 'normal', totalRamBytes: 0, availableRamBytes: 0, usedRamBytes: 0, lowMemory: false };
    const battery: BatteryHealth = { state: 'unknown', chargingType: 'none' };
    const power: PowerStatus = { dozeModeEnabled: false, lowPowerModeEnabled: false };
    const system: Record<string, string> = {};
    const payload: HealthPayload = { memory, battery, power, system };
    return JSON.stringify(payload);
  }
}
