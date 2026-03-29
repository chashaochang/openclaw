/**
 * Device invoke handler: status, info, permissions, health.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { notificationExtensionSubscription, notificationManager } from '@kit.NotificationKit';
import batteryInfo from '@ohos.batteryInfo';
import bundleManager from '@ohos.bundle.bundleManager';
import storageStatistics from '@ohos.file.storageStatistics';
import hidebug from '@ohos.hidebug';
import connection from '@ohos.net.connection';
import power from '@ohos.power';
import systemDateTime from '@ohos.systemDateTime';
import type { InvokeResult } from '../gateway/GatewaySession';
import { MotionHandler } from './MotionHandler';

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

interface BundleVersionInfo {
  versionName: string;
  versionCode: string;
}

export class DeviceHandler {
  private context: common.UIAbilityContext;

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

  async handleDevicePermissions(_paramsJson: string | null): Promise<InvokeResult> {
    const r: InvokeResult = { ok: true, payloadJson: await this.permissionsPayloadJson(), error: null };
    return r;
  }

  handleDeviceHealth(_paramsJson: string | null): InvokeResult {
    const r: InvokeResult = { ok: true, payloadJson: this.healthPayloadJson(), error: null };
    return r;
  }

  private statusPayloadJson(): string {
    const battery: BatteryStatus = {
      level: this.readBatteryLevel(),
      state: this.mapBatteryState(),
      lowPowerModeEnabled: this.isLowPowerModeEnabled(),
    };
    const thermal: ThermalStatus = { state: this.mapThermalState() };
    const storage = this.readStorageStatus();
    const network = this.readNetworkStatus();
    const uptimeSeconds = Math.max(0, Math.floor(this.readSystemUptimeMs() / 1000));
    const payload: StatusPayload = { battery, thermal, storage, network, uptimeSeconds: uptimeSeconds };
    return JSON.stringify(payload);
  }

  private infoPayloadJson(): string {
    const bundleInfo = this.readBundleInfo();
    const deviceName = this.readDeviceName();
    const modelIdentifier = this.readModelIdentifier(deviceName);
    const systemVersion = this.readSystemVersion();
    let locale = 'zh-CN';
    try {
      locale = i18n.System.getSystemLocale();
    } catch {
      // keep default
    }
    const payload: InfoPayload = {
      deviceName: deviceName,
      modelIdentifier: modelIdentifier,
      systemName: 'HarmonyOS',
      systemVersion: systemVersion,
      appVersion: bundleInfo.versionName,
      appBuild: bundleInfo.versionCode,
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

  private async permissionsPayloadJson(): Promise<string> {
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
    let notificationListenerGranted = false;
    try {
      notificationListenerGranted = await notificationExtensionSubscription.isUserGranted();
    } catch {
      notificationListenerGranted = false;
    }
    const notificationListener: PermissionEntry = {
      status: notificationListenerGranted ? 'granted' : 'denied',
      promptable: !notificationListenerGranted,
    };
    const photos = this.permissionEntryForAny(['ohos.permission.READ_IMAGEVIDEO']);
    const contacts = this.permissionEntryForAll([
      'ohos.permission.READ_CONTACTS',
      'ohos.permission.WRITE_CONTACTS',
    ]);
    const calendar = this.permissionEntryForAll([
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
    ]);
    const motionUnavailable: PermissionEntry = { status: 'denied', promptable: false };
    const motion = MotionHandler.isAvailable()
      ? this.permissionEntryForAll([
          'ohos.permission.ACTIVITY_MOTION',
          'ohos.permission.ACCELEROMETER',
        ])
      : motionUnavailable;
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

  private permissionEntryForAll(permissionNames: Permissions[]): PermissionEntry {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return { status: 'denied', promptable: true };
    }
    const at = abilityAccessCtrl.createAtManager();
    const tokenId = ctx.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const s = at.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (s !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return { status: 'denied', promptable: true };
        }
      } catch {
        return { status: 'denied', promptable: true };
      }
    }
    return { status: 'granted', promptable: false };
  }

  private healthPayloadJson(): string {
    const memory = this.readMemoryStatus();
    const battery: BatteryHealth = {
      state: this.mapBatteryHealthState(),
      chargingType: this.mapChargingType(),
    };
    const powerStatus: PowerStatus = {
      dozeModeEnabled: this.isStandbyEnabled(),
      lowPowerModeEnabled: this.isLowPowerModeEnabled(),
    };
    const system: Record<string, string> = {};
    const batteryTemperatureC = this.readBatteryTemperatureC();
    if (batteryTemperatureC !== null) {
      system['batteryTemperatureC'] = batteryTemperatureC.toFixed(1);
    }
    const batteryCurrentMa = this.readBatteryCurrentMa();
    if (batteryCurrentMa !== null) {
      system['batteryCurrentMa'] = batteryCurrentMa.toFixed(0);
    }
    const technology = this.readBatteryTechnology();
    if (technology.length > 0) {
      system['batteryTechnology'] = technology;
    }
    const powerMode = this.readPowerModeName();
    if (powerMode.length > 0) {
      system['powerMode'] = powerMode;
    }
    const ramConstrained = this.readRamConstrainedFlag();
    if (ramConstrained !== null) {
      system['ramConstrained'] = ramConstrained ? 'true' : 'false';
    }
    const payload: HealthPayload = { memory, battery, power: powerStatus, system };
    return JSON.stringify(payload);
  }

  private readBatteryLevel(): number {
    try {
      const level = Number(batteryInfo.batterySOC);
      if (!Number.isFinite(level)) {
        return 1;
      }
      return Math.max(0, Math.min(1, level / 100));
    } catch {
      return 1;
    }
  }

  private readBatteryTemperatureC(): number | null {
    try {
      const raw = Number(batteryInfo.batteryTemperature);
      if (!Number.isFinite(raw)) {
        return null;
      }
      return raw / 10;
    } catch {
      return null;
    }
  }

  private readBatteryCurrentMa(): number | null {
    try {
      const current = Number(batteryInfo.nowCurrent);
      return Number.isFinite(current) ? current : null;
    } catch {
      return null;
    }
  }

  private readBatteryTechnology(): string {
    try {
      return String(batteryInfo.technology ?? '').trim();
    } catch {
      return '';
    }
  }

  private mapBatteryState(): string {
    try {
      switch (batteryInfo.chargingStatus) {
        case batteryInfo.BatteryChargeState.ENABLE:
          return 'charging';
        case batteryInfo.BatteryChargeState.FULL:
          return 'full';
        case batteryInfo.BatteryChargeState.DISABLE:
          return 'unplugged';
        default:
          return 'unknown';
      }
    } catch {
      return 'unknown';
    }
  }

  private mapBatteryHealthState(): string {
    try {
      switch (batteryInfo.healthStatus) {
        case batteryInfo.BatteryHealthState.GOOD:
          return 'good';
        case batteryInfo.BatteryHealthState.OVERHEAT:
          return 'overheat';
        case batteryInfo.BatteryHealthState.OVERVOLTAGE:
          return 'overvoltage';
        case batteryInfo.BatteryHealthState.COLD:
          return 'cold';
        case batteryInfo.BatteryHealthState.DEAD:
          return 'dead';
        default:
          return 'unknown';
      }
    } catch {
      return 'unknown';
    }
  }

  private mapChargingType(): string {
    try {
      switch (batteryInfo.pluggedType) {
        case batteryInfo.BatteryPluggedType.AC:
          return 'ac';
        case batteryInfo.BatteryPluggedType.USB:
          return 'usb';
        case batteryInfo.BatteryPluggedType.WIRELESS:
          return 'wireless';
        default:
          return 'none';
      }
    } catch {
      return 'none';
    }
  }

  private mapThermalState(): string {
    try {
      switch (batteryInfo.healthStatus) {
        case batteryInfo.BatteryHealthState.OVERHEAT:
          return 'critical';
        case batteryInfo.BatteryHealthState.COLD:
          return 'fair';
        default:
          break;
      }
    } catch {
      // fall through to temperature-based heuristic
    }
    const temperatureC = this.readBatteryTemperatureC();
    if (temperatureC === null) {
      return 'nominal';
    }
    if (temperatureC >= 45) {
      return 'critical';
    }
    if (temperatureC >= 40) {
      return 'serious';
    }
    if (temperatureC >= 35) {
      return 'fair';
    }
    return 'nominal';
  }

  private readStorageStatus(): StorageStatus {
    let totalBytes = 0;
    let freeBytes = 0;
    try {
      totalBytes = Math.max(0, storageStatistics.getTotalSizeSync());
      freeBytes = Math.max(0, storageStatistics.getFreeSizeSync());
    } catch {
      totalBytes = 0;
      freeBytes = 0;
    }
    const usedBytes = Math.max(0, totalBytes - freeBytes);
    return { totalBytes, freeBytes, usedBytes };
  }

  private readNetworkStatus(): NetworkStatus {
    try {
      if (!connection.hasDefaultNetSync()) {
        return {
          status: 'unsatisfied',
          isExpensive: false,
          isConstrained: false,
          interfaces: ['other'],
        };
      }
      const netHandle = connection.getDefaultNetSync();
      const capabilities = connection.getNetCapabilitiesSync(netHandle);
      const properties = connection.getConnectionPropertiesSync(netHandle);
      const isMetered = connection.isDefaultNetMeteredSync();
      return {
        status: this.mapNetworkStatus(capabilities),
        isExpensive: isMetered,
        isConstrained: !this.hasNetCapability(capabilities, connection.NetCap.NET_CAPABILITY_NOT_METERED),
        interfaces: this.mapNetworkInterfaces(capabilities, properties.interfaceName),
      };
    } catch {
      return {
        status: 'unsatisfied',
        isExpensive: false,
        isConstrained: false,
        interfaces: ['other'],
      };
    }
  }

  private mapNetworkStatus(capabilities: connection.NetCapabilities): string {
    if (this.hasNetCapability(capabilities, connection.NetCap.NET_CAPABILITY_VALIDATED)) {
      return 'satisfied';
    }
    if (
      this.hasNetCapability(capabilities, connection.NetCap.NET_CAPABILITY_CHECKING_CONNECTIVITY) ||
      this.hasNetCapability(capabilities, connection.NetCap.NET_CAPABILITY_INTERNET)
    ) {
      return 'requiresConnection';
    }
    return 'unsatisfied';
  }

  private mapNetworkInterfaces(
    capabilities: connection.NetCapabilities,
    interfaceName: string,
  ): string[] {
    const result: string[] = [];
    const bearerTypes = capabilities.bearerTypes ?? [];
    for (let i = 0; i < bearerTypes.length; i++) {
      const bearer = bearerTypes[i];
      if (bearer === connection.NetBearType.BEARER_WIFI && !result.includes('wifi')) {
        result.push('wifi');
        continue;
      }
      if (bearer === connection.NetBearType.BEARER_CELLULAR && !result.includes('cellular')) {
        result.push('cellular');
        continue;
      }
      if (bearer === connection.NetBearType.BEARER_ETHERNET && !result.includes('wired')) {
        result.push('wired');
        continue;
      }
      if (bearer === connection.NetBearType.BEARER_BLUETOOTH && !result.includes('bluetooth')) {
        result.push('bluetooth');
        continue;
      }
      if (bearer === connection.NetBearType.BEARER_VPN && !result.includes('vpn')) {
        result.push('vpn');
      }
    }
    if (result.length === 0 && interfaceName.trim().length > 0) {
      result.push(interfaceName.trim());
    }
    if (result.length === 0) {
      result.push('other');
    }
    return result;
  }

  private hasNetCapability(capabilities: connection.NetCapabilities, capability: connection.NetCap): boolean {
    const values = capabilities.networkCap ?? [];
    return values.includes(capability);
  }

  private readSystemUptimeMs(): number {
    try {
      return Math.max(0, Number(systemDateTime.getUptime(systemDateTime.TimeType.STARTUP)));
    } catch {
      return 0;
    }
  }

  private readDeviceName(): string {
    const candidates = [
      String(deviceInfo.marketName ?? '').trim(),
      String(deviceInfo.productModelAlias ?? '').trim(),
      String(deviceInfo.productModel ?? '').trim(),
      String(deviceInfo.deviceType ?? '').trim(),
    ];
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length > 0) {
        return candidates[i];
      }
    }
    return 'HarmonyOS';
  }

  private readModelIdentifier(deviceName: string): string {
    const candidates = [
      String(deviceInfo.hardwareModel ?? '').trim(),
      String(deviceInfo.softwareModel ?? '').trim(),
      String(deviceInfo.productModel ?? '').trim(),
      String(deviceInfo.productSeries ?? '').trim(),
    ];
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length > 0) {
        return candidates[i];
      }
    }
    return deviceName;
  }

  private readSystemVersion(): string {
    const candidates = [
      String(deviceInfo.osFullName ?? '').trim(),
      String(deviceInfo.displayVersion ?? '').trim(),
    ];
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i].length > 0) {
        return candidates[i];
      }
    }
    return '';
  }

  private readBundleInfo(): BundleVersionInfo {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const versionName = String(info.versionName ?? '').trim() || 'dev';
      const versionCode = String(info.versionCode ?? 0);
      const result: BundleVersionInfo = { versionName, versionCode };
      return result;
    } catch {
      const fallback: BundleVersionInfo = { versionName: 'dev', versionCode: '0' };
      return fallback;
    }
  }

  private readMemoryStatus(): MemoryStatus {
    try {
      const memInfo = hidebug.getSystemMemInfo();
      const totalRamBytes = this.kbBigIntToBytes(memInfo.totalMem);
      const availableRamBytes = this.kbBigIntToBytes(memInfo.availableMem);
      const usedRamBytes = Math.max(0, totalRamBytes - availableRamBytes);
      const pressure = this.mapMemoryPressure(totalRamBytes, availableRamBytes);
      const lowMemory = pressure === 'high' || pressure === 'critical';
      return {
        pressure,
        totalRamBytes,
        availableRamBytes,
        usedRamBytes,
        lowMemory,
      };
    } catch {
      return {
        pressure: 'unknown',
        totalRamBytes: 0,
        availableRamBytes: 0,
        usedRamBytes: 0,
        lowMemory: false,
      };
    }
  }

  private mapMemoryPressure(totalBytes: number, availableBytes: number): string {
    if (totalBytes <= 0) {
      return 'unknown';
    }
    const freeRatio = availableBytes / totalBytes;
    if (freeRatio <= 0.05) {
      return 'critical';
    }
    if (freeRatio <= 0.15) {
      return 'high';
    }
    if (freeRatio <= 0.30) {
      return 'moderate';
    }
    return 'normal';
  }

  private isStandbyEnabled(): boolean {
    try {
      return power.isStandby();
    } catch {
      return false;
    }
  }

  private isLowPowerModeEnabled(): boolean {
    try {
      const mode = power.getPowerMode();
      return (
        mode === power.DevicePowerMode.MODE_POWER_SAVE ||
        mode === power.DevicePowerMode.MODE_EXTREME_POWER_SAVE ||
        mode === power.DevicePowerMode.MODE_CUSTOM_POWER_SAVE
      );
    } catch {
      return false;
    }
  }

  private readPowerModeName(): string {
    try {
      switch (power.getPowerMode()) {
        case power.DevicePowerMode.MODE_NORMAL:
          return 'normal';
        case power.DevicePowerMode.MODE_POWER_SAVE:
          return 'powerSave';
        case power.DevicePowerMode.MODE_PERFORMANCE:
          return 'performance';
        case power.DevicePowerMode.MODE_EXTREME_POWER_SAVE:
          return 'extremePowerSave';
        case power.DevicePowerMode.MODE_CUSTOM_POWER_SAVE:
          return 'customPowerSave';
        default:
          return '';
      }
    } catch {
      return '';
    }
  }

  private readRamConstrainedFlag(): boolean | null {
    try {
      const limit = hidebug.getSystemMemInfo();
      return this.kbBigIntToBytes(limit.totalMem) <= 3 * 1024 * 1024 * 1024;
    } catch {
      return null;
    }
  }

  private kbBigIntToBytes(value: bigint): number {
    const bytes = Number(value) * 1024;
    if (!Number.isFinite(bytes)) {
      return Number.MAX_SAFE_INTEGER;
    }
    if (bytes < 0) {
      return 0;
    }
    return bytes;
  }
}
