/**
 * Device invoke handler: status, info, permissions, health.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { notificationManager } from '@kit.NotificationKit';
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
  private context: common.UIAbilityContext;
  private startedAtMs: number = Date.now();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

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
    const uptimeSeconds = Math.max(0, Math.floor((Date.now() - this.startedAtMs) / 1000));
    const payload: StatusPayload = { battery, thermal, storage, network, uptimeSeconds: uptimeSeconds };
    return JSON.stringify(payload);
  }

  private infoPayloadJson(): string {
    const deviceName = deviceInfo.deviceType ?? 'HarmonyOS';
    const systemVersion = deviceInfo.osFullName ?? '';
    let locale = 'zh-CN';
    try {
      locale = i18n.System.getSystemLocale();
    } catch {
      // keep default
    }
    const payload: InfoPayload = {
      deviceName: deviceName,
      modelIdentifier: deviceName,
      systemName: 'HarmonyOS',
      systemVersion: systemVersion,
      appVersion: APP_VERSION,
      appBuild: APP_BUILD,
      locale: locale,
    };
    return JSON.stringify(payload);
  }

  private permissionEntryForAny(permissionNames: Permissions[]): PermissionEntry {
    const at = abilityAccessCtrl.createAtManager();
    const tokenId = this.context.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      const p = permissionNames[i];
      try {
        const s = at.checkAccessTokenSync(tokenId, p);
        if (s === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          const e: PermissionEntry = { status: 'granted', promptable: false };
          return e;
        }
      } catch {
        // ignored: unknown permission on this API/device
      }
    }
    const denied: PermissionEntry = { status: 'denied', promptable: true };
    return denied;
  }

  private permissionsPayloadJson(): string {
    const camera = this.permissionEntryForAny(['ohos.permission.CAMERA']);
    const microphone = this.permissionEntryForAny(['ohos.permission.MICROPHONE']);
    const location = this.permissionEntryForAny([
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION',
    ]);
    let notificationsGranted = false;
    try {
      notificationsGranted = notificationManager.isNotificationEnabledSync();
    } catch {
      notificationsGranted = false;
    }
    const notifications: PermissionEntry = {
      status: notificationsGranted ? 'granted' : 'denied',
      promptable: !notificationsGranted,
    };
    const notificationListener: PermissionEntry = {
      status: 'denied',
      promptable: true,
    };
    const photos: PermissionEntry = { status: 'denied', promptable: false };
    const contacts: PermissionEntry = { status: 'denied', promptable: false };
    const calendar: PermissionEntry = { status: 'denied', promptable: false };
    const motion: PermissionEntry = { status: 'denied', promptable: false };
    const sms: PermissionEntry = { status: 'denied', promptable: false };
    const callLog: PermissionEntry = { status: 'denied', promptable: false };
    const permissions: Record<string, PermissionEntry> = {};
    permissions['camera'] = camera;
    permissions['microphone'] = microphone;
    permissions['location'] = location;
    permissions['notifications'] = notifications;
    permissions['notificationListener'] = notificationListener;
    permissions['photos'] = photos;
    permissions['contacts'] = contacts;
    permissions['calendar'] = calendar;
    permissions['motion'] = motion;
    permissions['sms'] = sms;
    permissions['callLog'] = callLog;
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
