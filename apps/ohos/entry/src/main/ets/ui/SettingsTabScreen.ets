/**
 * Settings tab: gateway summary, features, permissions, device identity, pairing (Android SettingsSheet parity).
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { notificationExtensionSubscription, notificationManager } from '@kit.NotificationKit';
import {
  normalizeLocalHourMinute,
  NotificationPackageFilterMode,
} from '../common/NotificationForwardingPolicy';
import { NodeRuntime } from '../NodeRuntime';
import { MotionHandler } from '../node/MotionHandler';
import { LocationMode } from '../LocationMode';
import { VoiceWakeMode } from '../voice/VoiceWakeMode';

interface StatusChipColorSet {
  bg: string;
  border: string;
  text: string;
}

@Component
export struct SettingsTabScreen {
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime =
    AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State instanceId: string = '';
  @State displayName: string = '';
  @State isConnected: boolean = false;
  @State connectionStatusText: string = '';
  @State remoteAddress: string = '';
  @State manualHost: string = '';
  @State manualPort: string = '';
  @State manualTls: boolean = false;
  @State voiceWakeMode: VoiceWakeMode = VoiceWakeMode.Foreground;
  @State voiceWakeWordsDraft: string = '';
  @State voiceWakeStatusText: string = 'Off';
  @State voiceWakeListening: boolean = false;
  @State voiceSpeakerOn: boolean = true;
  @State cameraEnabled: boolean = true;
  @State canvasDebugOn: boolean = false;
  @State locationMode: LocationMode = LocationMode.Off;
  @State locationPreciseEnabled: boolean = true;
  @State preventSleep: boolean = true;
  @State hasMicPermission: boolean = false;
  @State hasCameraPermission: boolean = false;
  @State hasLocationPermission: boolean = false;
  @State hasPhotosPermission: boolean = false;
  @State hasContactsPermission: boolean = false;
  @State hasCalendarPermission: boolean = false;
  @State hasMotionPermission: boolean = false;
  @State notificationsEnabled: boolean = false;
  @State notificationListenerEnabled: boolean = false;
  @State notificationForwardingEnabled: boolean = false;
  @State notificationForwardingMode: NotificationPackageFilterMode = NotificationPackageFilterMode.Blocklist;
  @State notificationForwardingPackagesCsvDraft: string = '';
  @State notificationForwardingQuietHoursEnabled: boolean = false;
  @State notificationForwardingQuietStart: string = '22:00';
  @State notificationForwardingQuietEnd: string = '07:00';
  @State notificationForwardingRateDraft: string = '30';
  @State notificationForwardingSessionKeyDraft: string = '';
  @State recentNotificationPackages: string[] = [];
  @State refreshBusy: boolean = false;
  private readonly motionAvailable: boolean = MotionHandler.isAvailable();

  private resStr(res: Resource): string {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return '';
    }
    try {
      return ctx.resourceManager.getStringSync(res);
    } catch {
      return '';
    }
  }

  private resFmt1(res: Resource, a: string): string {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return a;
    }
    try {
      return ctx.resourceManager.getStringSync(res, a);
    } catch {
      return a;
    }
  }

  private shortInstanceId(full: string): string {
    const t = (full ?? '').trim();
    if (t.length === 0 || t === '—') {
      return '—';
    }
    if (t.length <= 14) {
      return t;
    }
    return `${t.substring(0, 8)}…`;
  }

  private refreshMicPermission(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      this.hasMicPermission = false;
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const tokenId = ctx.applicationInfo.accessTokenId;
      const mic: Permissions = 'ohos.permission.MICROPHONE';
      const s = at.checkAccessTokenSync(tokenId, mic);
      this.hasMicPermission = s === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch {
      this.hasMicPermission = false;
    }
  }

  private refreshCameraPermission(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      this.hasCameraPermission = false;
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const tokenId = ctx.applicationInfo.accessTokenId;
      const cam: Permissions = 'ohos.permission.CAMERA';
      const s = at.checkAccessTokenSync(tokenId, cam);
      this.hasCameraPermission = s === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch {
      this.hasCameraPermission = false;
    }
  }

  private refreshLocationPermission(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      this.hasLocationPermission = false;
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const tokenId = ctx.applicationInfo.accessTokenId;
      const p1: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
      const p2: Permissions = 'ohos.permission.LOCATION';
      const s1 = at.checkAccessTokenSync(tokenId, p1);
      const s2 = at.checkAccessTokenSync(tokenId, p2);
      this.hasLocationPermission =
        s1 === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ||
        s2 === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch {
      this.hasLocationPermission = false;
    }
  }

  private refreshPhotosPermission(): void {
    this.hasPhotosPermission = this.readPermissionGranted(['ohos.permission.READ_IMAGEVIDEO']);
  }

  private refreshContactsPermission(): void {
    this.hasContactsPermission = this.allPermissionsGranted([
      'ohos.permission.READ_CONTACTS',
      'ohos.permission.WRITE_CONTACTS',
    ]);
  }

  private refreshCalendarPermission(): void {
    this.hasCalendarPermission = this.allPermissionsGranted([
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
    ]);
  }

  private refreshMotionPermission(): void {
    this.hasMotionPermission = this.allPermissionsGranted([
      'ohos.permission.ACTIVITY_MOTION',
      'ohos.permission.ACCELEROMETER',
    ]);
  }

  private async refreshNotificationsEnabled(): Promise<void> {
    try {
      this.notificationsEnabled = await notificationManager.isNotificationEnabled();
    } catch {
      this.notificationsEnabled = false;
    }
    try {
      this.notificationListenerEnabled = await notificationExtensionSubscription.isUserGranted();
    } catch {
      this.notificationListenerEnabled = false;
    }
  }

  private async reloadFromRuntime(): Promise<void> {
    const id = await this.nodeRuntime.getInstanceId();
    this.instanceId = id && id.trim().length > 0 ? id.trim() : '—';
    const name = await this.nodeRuntime.getDisplayName();
    this.displayName = name ?? '';
    this.manualHost = await this.nodeRuntime.getManualHost();
    this.manualPort = await this.nodeRuntime.getManualPort();
    this.manualTls = await this.nodeRuntime.getManualTls();
    this.isConnected = this.nodeRuntime.getIsConnected();
    this.connectionStatusText = this.nodeRuntime.getStatusText();
    this.remoteAddress = this.nodeRuntime.getRemoteAddress();
    this.voiceWakeMode = await this.nodeRuntime.getVoiceWakeMode();
    this.voiceWakeWordsDraft = await this.nodeRuntime.getVoiceWakeWordsCsv();
    this.voiceWakeStatusText = this.nodeRuntime.getVoiceWakeStatusText();
    this.voiceWakeListening = this.nodeRuntime.getVoiceWakeListening();
    this.voiceSpeakerOn = this.nodeRuntime.getVoiceSpeakerEnabled();
    this.cameraEnabled = await this.nodeRuntime.getCameraEnabled();
    this.canvasDebugOn = await this.nodeRuntime.getCanvasDebugEnabled();
    this.locationMode = await this.nodeRuntime.getLocationMode();
    this.locationPreciseEnabled = await this.nodeRuntime.getLocationPreciseEnabled();
    this.preventSleep = await this.nodeRuntime.getPreventSleep();
    this.notificationForwardingEnabled = await this.nodeRuntime.getNotificationForwardingEnabled();
    this.notificationForwardingMode = await this.nodeRuntime.getNotificationForwardingMode();
    this.notificationForwardingPackagesCsvDraft =
      await this.nodeRuntime.getNotificationForwardingPackagesCsv();
    this.notificationForwardingQuietHoursEnabled =
      await this.nodeRuntime.getNotificationForwardingQuietHoursEnabled();
    this.notificationForwardingQuietStart = await this.nodeRuntime.getNotificationForwardingQuietStart();
    this.notificationForwardingQuietEnd = await this.nodeRuntime.getNotificationForwardingQuietEnd();
    this.notificationForwardingRateDraft =
      String(await this.nodeRuntime.getNotificationForwardingMaxEventsPerMinute());
    this.notificationForwardingSessionKeyDraft =
      await this.nodeRuntime.getNotificationForwardingSessionKey();
    this.recentNotificationPackages = await this.nodeRuntime.getRecentNotificationPackages();
    this.refreshMicPermission();
    this.refreshCameraPermission();
    this.refreshLocationPermission();
    this.refreshPhotosPermission();
    this.refreshContactsPermission();
    this.refreshCalendarPermission();
    this.refreshMotionPermission();
    await this.refreshNotificationsEnabled();
  }

  aboutToAppear(): void {
    void this.reloadFromRuntime();
  }

  onPageShow(): void {
    void this.reloadFromRuntime();
  }

  private openAppSettings(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    try {
      void ctx.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
      });
    } catch {
      // best-effort
    }
  }

  private async requestMic(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    const mic: Permissions = 'ohos.permission.MICROPHONE';
    try {
      const result = await at.requestPermissionsFromUser(ctx, [mic]);
      const ok =
        result.authResults.length > 0 &&
        result.authResults.every((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
      this.hasMicPermission = ok;
    } catch {
      this.refreshMicPermission();
    }
  }

  private async requestCamera(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    const cam: Permissions = 'ohos.permission.CAMERA';
    try {
      const result = await at.requestPermissionsFromUser(ctx, [cam]);
      const ok =
        result.authResults.length > 0 &&
        result.authResults.every((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
      this.hasCameraPermission = ok;
    } catch {
      this.refreshCameraPermission();
    }
  }

  private async requestLocation(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    const p1: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
    const p2: Permissions = 'ohos.permission.LOCATION';
    try {
      const result = await at.requestPermissionsFromUser(ctx, [p1, p2]);
      const ok =
        result.authResults.length > 0 &&
        result.authResults.some((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
      this.hasLocationPermission = ok;
    } catch {
      this.refreshLocationPermission();
    }
  }

  private hasFineLocationPermission(): boolean {
    return this.readPermissionGranted(['ohos.permission.LOCATION']);
  }

  private async requestPreciseLocation(): Promise<boolean> {
    const ok = await this.requestSimplePermission(['ohos.permission.LOCATION']);
    this.refreshLocationPermission();
    return ok && this.hasFineLocationPermission();
  }

  private async setCameraEnabledChecked(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.cameraEnabled = false;
      await this.nodeRuntime.setCameraEnabled(false);
      return;
    }
    if (!this.hasCameraPermission) {
      await this.requestCamera();
    }
    const resolved = this.hasCameraPermission;
    this.cameraEnabled = resolved;
    await this.nodeRuntime.setCameraEnabled(resolved);
  }

  private async setLocationModeChecked(mode: LocationMode): Promise<void> {
    if (mode === LocationMode.Off) {
      this.locationMode = LocationMode.Off;
      await this.nodeRuntime.setLocationMode(LocationMode.Off);
      return;
    }
    if (!this.hasLocationPermission) {
      await this.requestLocation();
    }
    const resolved = this.hasLocationPermission ? LocationMode.WhileUsing : LocationMode.Off;
    this.locationMode = resolved;
    await this.nodeRuntime.setLocationMode(resolved);
  }

  private async setPreciseLocationChecked(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.locationPreciseEnabled = false;
      await this.nodeRuntime.setLocationPreciseEnabled(false);
      return;
    }
    if (this.locationMode === LocationMode.Off) {
      return;
    }
    let resolved = this.hasFineLocationPermission();
    if (!resolved) {
      resolved = await this.requestPreciseLocation();
    }
    this.locationPreciseEnabled = resolved;
    await this.nodeRuntime.setLocationPreciseEnabled(resolved);
  }

  private async requestPhotos(): Promise<void> {
    const ok = await this.requestSimplePermission(['ohos.permission.READ_IMAGEVIDEO']);
    this.hasPhotosPermission = ok;
  }

  private async requestContacts(): Promise<void> {
    const ok = await this.requestSimplePermission([
      'ohos.permission.READ_CONTACTS',
      'ohos.permission.WRITE_CONTACTS',
    ]);
    this.hasContactsPermission = ok;
  }

  private async requestCalendar(): Promise<void> {
    const ok = await this.requestSimplePermission([
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
    ]);
    this.hasCalendarPermission = ok;
  }

  private async requestMotion(): Promise<void> {
    const ok = await this.requestSimplePermission([
      'ohos.permission.ACTIVITY_MOTION',
      'ohos.permission.ACCELEROMETER',
    ]);
    this.hasMotionPermission = ok;
  }

  private async requestNotifications(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    try {
      await notificationManager.requestEnableNotification(ctx);
    } catch {
      // best-effort
    }
    await this.refreshNotificationsEnabled();
  }

  private async requestNotificationListener(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    try {
      await notificationExtensionSubscription.openSubscriptionSettings(ctx);
    } catch {
      this.openAppSettings();
    }
    await this.refreshNotificationsEnabled();
  }

  private async setNotificationForwardingEnabledChecked(enabled: boolean): Promise<void> {
    this.notificationForwardingEnabled = enabled;
    await this.nodeRuntime.setNotificationForwardingEnabled(enabled);
  }

  private notificationForwardingControlsEnabled(): boolean {
    return this.notificationListenerEnabled && this.notificationForwardingEnabled;
  }

  private async setVoiceWakeModeChecked(mode: VoiceWakeMode): Promise<void> {
    if (mode !== VoiceWakeMode.Off && !this.hasMicPermission) {
      await this.requestMic();
    }
    if (mode !== VoiceWakeMode.Off && !this.hasMicPermission) {
      this.voiceWakeMode = VoiceWakeMode.Off;
      await this.nodeRuntime.setVoiceWakeMode(VoiceWakeMode.Off);
      await this.reloadFromRuntime();
      return;
    }
    this.voiceWakeMode = mode;
    await this.nodeRuntime.setVoiceWakeMode(mode);
    await this.reloadFromRuntime();
  }

  private async saveVoiceWakeWords(): Promise<void> {
    await this.nodeRuntime.setVoiceWakeWordsCsv(this.voiceWakeWordsDraft);
    this.voiceWakeWordsDraft = await this.nodeRuntime.getVoiceWakeWordsCsv();
    this.voiceWakeStatusText = this.nodeRuntime.getVoiceWakeStatusText();
    this.voiceWakeListening = this.nodeRuntime.getVoiceWakeListening();
  }

  private voiceWakeAlwaysNoteVisible(): boolean {
    return this.voiceWakeMode === VoiceWakeMode.Always;
  }

  private parseNotificationForwardingPackagesCsv(raw: string): string[] {
    if (raw.trim().length === 0) {
      return [];
    }
    const parts = raw.split(/[\n,]/);
    const seen = new Set<string>();
    const packages: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const value = parts[i].trim();
      if (value.length === 0 || seen.has(value)) {
        continue;
      }
      seen.add(value);
      packages.push(value);
    }
    return packages;
  }

  private notificationForwardingPackagesCount(): number {
    return this.parseNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft).length;
  }

  private isNotificationForwardingPackageConfigured(packageName: string): boolean {
    const packages = this.parseNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft);
    for (let i = 0; i < packages.length; i++) {
      if (packages[i] === packageName) {
        return true;
      }
    }
    return false;
  }

  private async setNotificationForwardingModeChecked(mode: NotificationPackageFilterMode): Promise<void> {
    this.notificationForwardingMode = mode;
    await this.nodeRuntime.setNotificationForwardingMode(mode);
  }

  private async saveNotificationForwardingPackagesCsv(): Promise<void> {
    const packages = this.parseNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft);
    this.notificationForwardingPackagesCsvDraft = packages.join(', ');
    await this.nodeRuntime.setNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft);
  }

  private async toggleRecentNotificationPackage(packageName: string): Promise<void> {
    const packages = this.parseNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft);
    const next: string[] = [];
    let removed = false;
    for (let i = 0; i < packages.length; i++) {
      if (packages[i] === packageName) {
        removed = true;
        continue;
      }
      next.push(packages[i]);
    }
    if (!removed) {
      next.push(packageName);
    }
    this.notificationForwardingPackagesCsvDraft = next.join(', ');
    await this.nodeRuntime.setNotificationForwardingPackagesCsv(this.notificationForwardingPackagesCsvDraft);
  }

  private async saveNotificationForwardingRate(): Promise<void> {
    const parsed = parseInt(this.notificationForwardingRateDraft.trim(), 10);
    if (!Number.isFinite(parsed) || parsed < 1) {
      promptAction.showToast({
        message: this.resStr($r('app.string.settings_notification_forwarding_rate_invalid')),
      });
      return;
    }
    await this.nodeRuntime.setNotificationForwardingMaxEventsPerMinute(parsed);
    this.notificationForwardingRateDraft = String(Math.max(1, Math.floor(parsed)));
  }

  private async saveNotificationForwardingSessionKey(): Promise<void> {
    await this.nodeRuntime.setNotificationForwardingSessionKey(
      this.notificationForwardingSessionKeyDraft.trim(),
    );
  }

  private async setNotificationForwardingQuietHoursChecked(enabled: boolean): Promise<void> {
    if (!enabled) {
      const ok = await this.nodeRuntime.setNotificationForwardingQuietHours(
        false,
        this.notificationForwardingQuietStart,
        this.notificationForwardingQuietEnd,
      );
      if (ok) {
        this.notificationForwardingQuietHoursEnabled = false;
      }
      return;
    }
    const normalizedStart = normalizeLocalHourMinute(this.notificationForwardingQuietStart);
    const normalizedEnd = normalizeLocalHourMinute(this.notificationForwardingQuietEnd);
    if (!normalizedStart || !normalizedEnd) {
      promptAction.showToast({
        message: this.resStr($r('app.string.settings_notification_forwarding_quiet_invalid')),
      });
      return;
    }
    const ok = await this.nodeRuntime.setNotificationForwardingQuietHours(
      true,
      normalizedStart,
      normalizedEnd,
    );
    if (ok) {
      this.notificationForwardingQuietStart = normalizedStart;
      this.notificationForwardingQuietEnd = normalizedEnd;
      this.notificationForwardingQuietHoursEnabled = true;
    }
  }

  private async saveNotificationForwardingQuietHours(): Promise<void> {
    const normalizedStart = normalizeLocalHourMinute(this.notificationForwardingQuietStart);
    const normalizedEnd = normalizeLocalHourMinute(this.notificationForwardingQuietEnd);
    if (!normalizedStart || !normalizedEnd) {
      promptAction.showToast({
        message: this.resStr($r('app.string.settings_notification_forwarding_quiet_invalid')),
      });
      return;
    }
    const ok = await this.nodeRuntime.setNotificationForwardingQuietHours(
      this.notificationForwardingQuietHoursEnabled,
      normalizedStart,
      normalizedEnd,
    );
    if (!ok) {
      promptAction.showToast({
        message: this.resStr($r('app.string.settings_notification_forwarding_quiet_invalid')),
      });
      return;
    }
    this.notificationForwardingQuietStart = normalizedStart;
    this.notificationForwardingQuietEnd = normalizedEnd;
  }

  private endpointLine(): string {
    const h = (this.manualHost ?? '').trim();
    const p = (this.manualPort ?? '').trim();
    if (h.length === 0) {
      return '—';
    }
    const tls = this.resStr($r('app.string.settings_tls_badge'));
    const tcp = this.resStr($r('app.string.settings_tcp_badge'));
    return `${h}:${p.length > 0 ? p : '?'} · ${this.manualTls ? tls : tcp}`;
  }

  private readPermissionGranted(permissionNames: Permissions[]): boolean {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return false;
    }
    const at = abilityAccessCtrl.createAtManager();
    const tokenId = ctx.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = at.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch {
        // Ignore unsupported permission names on some Harmony builds.
      }
    }
    return false;
  }

  private allPermissionsGranted(permissionNames: Permissions[]): boolean {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return false;
    }
    const at = abilityAccessCtrl.createAtManager();
    const tokenId = ctx.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = at.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return false;
        }
      } catch {
        return false;
      }
    }
    return permissionNames.length > 0;
  }

  private async requestSimplePermission(permissionNames: Permissions[]): Promise<boolean> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return false;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const result = await at.requestPermissionsFromUser(ctx, permissionNames);
      return result.authResults.length > 0 &&
        result.authResults.every((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
    } catch {
      return this.allPermissionsGranted(permissionNames);
    }
  }

  private statusChipColors(): StatusChipColorSet {
    if (this.isConnected) {
      const c: StatusChipColorSet = {
        bg: '#E8F5E9',
        border: 'rgba(47, 140, 90, 0.28)',
        text: '#2F8C5A',
      };
      return c;
    }
    const lower = this.connectionStatusText.toLowerCase();
    if (lower.includes('connecting') || lower.includes('reconnecting')) {
      const c: StatusChipColorSet = {
        bg: '#ECF3FF',
        border: '#D5E2FA',
        text: '#1D5DD8',
      };
      return c;
    }
    if (lower.includes('error') || lower.includes('failed')) {
      const c: StatusChipColorSet = {
        bg: '#FFEBEE',
        border: 'rgba(220, 53, 69, 0.25)',
        text: '#dc3545',
      };
      return c;
    }
    const c: StatusChipColorSet = {
      bg: '#F6F7FA',
      border: '#E5E7EC',
      text: '#4D5563',
    };
    return c;
  }

  @Builder
  SectionHeader(label: Resource) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor('#1D5DD8')
      .letterSpacing(0.8)
      .width('100%')
      .margin({ top: 8, bottom: 2 })
  }

  @Builder
  NotificationFilterModeButton(
    mode: NotificationPackageFilterMode,
    label: Resource,
    subtitle: Resource,
  ) {
    Button() {
      Column({ space: 4 }) {
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.notificationForwardingMode === mode ? '#1D5DD8' : '#17181C')
        Text(subtitle)
          .fontSize(11)
          .fontColor(this.notificationForwardingMode === mode ? '#1D5DD8' : '#8A92A2')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
      .type(ButtonType.Normal)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.notificationForwardingMode === mode ? '#ECF3FF' : '#FFFFFF')
      .borderRadius(12)
      .border({
        width: 1,
        color: this.notificationForwardingMode === mode ? '#BFD5FF' : '#E5E7EC',
      })
      .enabled(this.notificationForwardingControlsEnabled())
      .onClick(() => {
        void this.setNotificationForwardingModeChecked(mode);
      })
  }

  @Builder
  VoiceWakeModeButton(
    mode: VoiceWakeMode,
    label: Resource,
    subtitle: Resource,
  ) {
    Button() {
      Column({ space: 4 }) {
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.voiceWakeMode === mode ? '#1D5DD8' : '#17181C')
        Text(subtitle)
          .fontSize(11)
          .fontColor(this.voiceWakeMode === mode ? '#1D5DD8' : '#8A92A2')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.voiceWakeMode === mode ? '#ECF3FF' : '#FFFFFF')
      .borderRadius(12)
      .border({
        width: 1,
        color: this.voiceWakeMode === mode ? '#BFD5FF' : '#E5E7EC',
      })
      .onClick(() => {
        void this.setVoiceWakeModeChecked(mode);
      })
  }

  @Builder
  RecentNotificationPackageRow(packageName: string) {
    Row({ space: 10 }) {
      Text(packageName)
        .fontSize(13)
        .fontColor('#17181C')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button(
        this.isNotificationForwardingPackageConfigured(packageName) ?
          this.resStr($r('app.string.settings_notification_forwarding_recent_remove')) :
          this.resStr($r('app.string.settings_notification_forwarding_recent_add')),
      )
        .height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor(
          this.isNotificationForwardingPackageConfigured(packageName) ? '#FFF4E5' : '#EEF1F6',
        )
        .fontColor('#17181C')
        .borderRadius(10)
        .enabled(this.notificationForwardingControlsEnabled())
        .onClick(() => {
          void this.toggleRecentNotificationPackage(packageName);
        })
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        Column({ space: 6 }) {
          Text($r('app.string.settings_section_settings'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1D5DD8')
          Text($r('app.string.settings_device_configuration_title'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
          Text($r('app.string.settings_device_configuration_subtitle'))
            .fontSize(14)
            .fontColor('#4D5563')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Divider().strokeWidth(1).color('#E5E7EC').width('100%')

        this.SectionHeader($r('app.string.settings_section_gateway'))

        Column({ space: 10 }) {
          Row() {
            Text(this.connectionStatusText.length > 0 ? this.connectionStatusText : 'Offline')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.statusChipColors().text)
              .layoutWeight(1)
            if (this.remoteAddress.trim().length > 0) {
              Text(this.remoteAddress)
                .fontSize(12)
                .fontColor('#8A92A2')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '46%' })
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.statusChipColors().bg)
          .borderRadius(12)
          .border({ width: 1, color: this.statusChipColors().border })

          Column({ space: 4 }) {
            Text($r('app.string.settings_gateway_endpoint_label'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#8A92A2')
            Text(this.endpointLine())
              .fontSize(15)
              .fontColor('#17181C')
              .fontFamily('monospace')
            Text($r('app.string.settings_gateway_manual_hint'))
              .fontSize(12)
              .fontColor('#8A92A2')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Button(
            this.refreshBusy ?
              this.resStr($r('app.string.settings_gateway_refresh_busy')) :
              this.resStr($r('app.string.settings_gateway_refresh')),
          )
            .width('100%')
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#1D5DD8')
            .borderRadius(14)
            .enabled(!this.refreshBusy)
            .onClick(async () => {
              this.refreshBusy = true;
              try {
                await this.nodeRuntime.refreshGatewayConnection();
                await this.reloadFromRuntime();
              } catch {
                promptAction.showToast({
                  message: this.resStr($r('app.string.settings_refresh_failed')) || 'Refresh failed',
                });
                await this.reloadFromRuntime();
              } finally {
                this.refreshBusy = false;
              }
            })
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader($r('app.string.settings_section_features'))

        Column({ space: 0 }) {
          Column({ space: 12 }) {
            Row() {
              Column({ space: 4 }) {
                Text($r('app.string.settings_voice_wake_title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#17181C')
                Text($r('app.string.settings_voice_wake_subtitle'))
                  .fontSize(13)
                  .fontColor('#8A92A2')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(this.voiceWakeListening ? this.resStr($r('app.string.settings_voice_wake_status_listening')) : this.voiceWakeStatusText)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.voiceWakeListening ? '#2F8C5A' : '#4D5563')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(this.voiceWakeListening ? '#E8F5E9' : '#F6F7FA')
                .borderRadius(999)
            }
            .width('100%')

            Row({ space: 10 }) {
              this.VoiceWakeModeButton(
                VoiceWakeMode.Off,
                $r('app.string.settings_voice_wake_mode_off'),
                $r('app.string.settings_voice_wake_mode_off_sub'),
              )
              this.VoiceWakeModeButton(
                VoiceWakeMode.Foreground,
                $r('app.string.settings_voice_wake_mode_foreground'),
                $r('app.string.settings_voice_wake_mode_foreground_sub'),
              )
              this.VoiceWakeModeButton(
                VoiceWakeMode.Always,
                $r('app.string.settings_voice_wake_mode_always'),
                $r('app.string.settings_voice_wake_mode_always_sub'),
              )
            }
            .width('100%')

            if (this.voiceWakeAlwaysNoteVisible()) {
              Text($r('app.string.settings_voice_wake_always_note'))
                .fontSize(12)
                .fontColor('#C8841A')
            }

            Column({ space: 6 }) {
              Text($r('app.string.settings_voice_wake_words_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Text($r('app.string.settings_voice_wake_words_subtitle'))
                .fontSize(12)
                .fontColor('#8A92A2')
              TextInput({
                placeholder: this.resStr($r('app.string.settings_voice_wake_words_placeholder')),
                text: this.voiceWakeWordsDraft,
              })
                .onChange((value: string) => {
                  this.voiceWakeWordsDraft = value;
                })
                .width('100%')
                .backgroundColor('#F7F8FA')
                .borderRadius(12)
                .border({ width: 1, color: '#E5E7EC' })
              Button($r('app.string.common_save'))
                .height(36)
                .backgroundColor('#EEF1F6')
                .fontColor('#17181C')
                .borderRadius(12)
                .onClick(() => {
                  void this.saveVoiceWakeWords();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_voice_speaker_default'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_voice_speaker_subtitle'))
                .fontSize(13)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.voiceSpeakerOn })
              .selectedColor('#1D5DD8')
              .onChange((v: boolean) => {
                this.voiceSpeakerOn = v;
                void this.nodeRuntime.setVoiceSpeakerEnabled(v);
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_feature_camera'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_feature_camera_subtitle'))
                .fontSize(13)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.cameraEnabled })
              .selectedColor('#1D5DD8')
              .onChange((v: boolean) => {
                void this.setCameraEnabledChecked(v);
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_prevent_sleep'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_prevent_sleep_subtitle'))
                .fontSize(13)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.preventSleep })
              .selectedColor('#1D5DD8')
              .onChange((v: boolean) => {
                this.preventSleep = v;
                void this.nodeRuntime.setPreventSleep(v);
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_canvas_debug'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_canvas_debug_subtitle'))
                .fontSize(13)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.canvasDebugOn })
              .selectedColor('#1D5DD8')
              .onChange((v: boolean) => {
                this.canvasDebugOn = v;
                void this.nodeRuntime.setCanvasDebugEnabled(v);
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader($r('app.string.settings_section_location'))

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Button($r('app.string.settings_location_off'))
              .layoutWeight(1)
              .height(42)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.locationMode === LocationMode.Off ? '#1D5DD8' : '#F6F7FA')
              .fontColor(this.locationMode === LocationMode.Off ? Color.White : '#4D5563')
              .borderRadius(12)
              .onClick(() => {
                void this.setLocationModeChecked(LocationMode.Off);
              })

            Button($r('app.string.settings_location_while_using'))
              .layoutWeight(1)
              .height(42)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.locationMode === LocationMode.WhileUsing ? '#1D5DD8' : '#F6F7FA')
              .fontColor(this.locationMode === LocationMode.WhileUsing ? Color.White : '#4D5563')
              .borderRadius(12)
              .onClick(() => {
                void this.setLocationModeChecked(LocationMode.WhileUsing);
              })
          }
          .width('100%')

          Text(
            this.locationMode === LocationMode.Off ?
              $r('app.string.settings_location_off_subtitle') :
              $r('app.string.settings_location_while_using_subtitle')
          )
            .fontSize(13)
            .fontColor('#8A92A2')

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_location_precise'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_location_precise_subtitle'))
                .fontSize(13)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.locationPreciseEnabled })
              .selectedColor('#1D5DD8')
              .enabled(this.locationMode !== LocationMode.Off)
              .onChange((v: boolean) => {
                void this.setPreciseLocationChecked(v);
              })
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader($r('app.string.settings_section_permissions'))

        Column({ space: 0 }) {
          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_notifications'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_notifications_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.notificationsEnabled ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.notificationsEnabled ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.notificationsEnabled ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.notificationsEnabled) {
                  this.openAppSettings();
                } else {
                  void this.requestNotifications();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_microphone'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_microphone_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasMicPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasMicPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasMicPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasMicPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestMic();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_camera'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_camera_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasCameraPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasCameraPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasCameraPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasCameraPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestCamera();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_location'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_location_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasLocationPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasLocationPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasLocationPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasLocationPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestLocation();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_notification_listener'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_notification_listener_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.notificationListenerEnabled ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.notificationListenerEnabled ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(this.notificationListenerEnabled ? this.resStr($r('app.string.settings_permission_manage')) : this.resStr($r('app.string.settings_permission_grant')))
              .height(36)
              .padding({ left: 18, right: 18 })
              .backgroundColor(this.notificationListenerEnabled ? '#EEF1F6' : '#17181C')
              .fontColor(this.notificationListenerEnabled ? '#17181C' : Color.White)
              .borderRadius(14)
              .onClick(() => {
                void this.requestNotificationListener();
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Column({ space: 12 }) {
            Row() {
              Column({ space: 4 }) {
                Text($r('app.string.settings_notification_forwarding_title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#17181C')
                Text($r('app.string.settings_notification_forwarding_sub'))
                  .fontSize(13)
                  .fontColor('#8A92A2')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.notificationForwardingEnabled })
                .selectedColor('#1D5DD8')
                .enabled(this.notificationListenerEnabled)
                .onChange((value: boolean) => {
                  void this.setNotificationForwardingEnabledChecked(value);
                })
            }
            .width('100%')
            if (!this.notificationListenerEnabled) {
              Text($r('app.string.settings_notification_forwarding_disabled_hint'))
                .fontSize(12)
                .fontColor('#C8841A')
            }

            Column({ space: 6 }) {
              Text($r('app.string.settings_notification_forwarding_filter_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Row({ space: 10 }) {
                this.NotificationFilterModeButton(
                  NotificationPackageFilterMode.Allowlist,
                  $r('app.string.settings_notification_forwarding_mode_allowlist'),
                  $r('app.string.settings_notification_forwarding_mode_allowlist_sub'),
                )
                this.NotificationFilterModeButton(
                  NotificationPackageFilterMode.Blocklist,
                  $r('app.string.settings_notification_forwarding_mode_blocklist'),
                  $r('app.string.settings_notification_forwarding_mode_blocklist_sub'),
                )
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text($r('app.string.settings_notification_forwarding_packages_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Text($r('app.string.settings_notification_forwarding_packages_sub'))
                .fontSize(12)
                .fontColor('#8A92A2')
              TextInput({
                placeholder: this.resStr($r('app.string.settings_notification_forwarding_packages_placeholder')),
                text: this.notificationForwardingPackagesCsvDraft,
              })
                .enabled(this.notificationForwardingControlsEnabled())
                .onChange((value: string) => {
                  this.notificationForwardingPackagesCsvDraft = value;
                })
                .width('100%')
                .backgroundColor('#F7F8FA')
                .borderRadius(12)
                .border({ width: 1, color: '#E5E7EC' })
              Text(
                this.notificationForwardingPackagesCount() > 0 ?
                  `${this.notificationForwardingPackagesCount()} configured` :
                  this.resStr($r('app.string.settings_notification_forwarding_packages_empty')),
              )
                .fontSize(11)
                .fontColor('#8A92A2')
              Button($r('app.string.common_save'))
                .height(36)
                .backgroundColor('#EEF1F6')
                .fontColor('#17181C')
                .borderRadius(12)
                .enabled(this.notificationForwardingControlsEnabled())
                .onClick(() => {
                  void this.saveNotificationForwardingPackagesCsv();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 8 }) {
              Text($r('app.string.settings_notification_forwarding_recent_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              if (this.recentNotificationPackages.length === 0) {
                Text($r('app.string.settings_notification_forwarding_recent_empty'))
                  .fontSize(12)
                  .fontColor('#8A92A2')
              } else {
                ForEach(this.recentNotificationPackages, (packageName: string) => {
                  this.RecentNotificationPackageRow(packageName)
                })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text($r('app.string.settings_notification_forwarding_session_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Text($r('app.string.settings_notification_forwarding_session_sub'))
                .fontSize(12)
                .fontColor('#8A92A2')
              TextInput({
                placeholder: 'main',
                text: this.notificationForwardingSessionKeyDraft,
              })
                .enabled(this.notificationForwardingControlsEnabled())
                .onChange((value: string) => {
                  this.notificationForwardingSessionKeyDraft = value;
                })
                .width('100%')
                .backgroundColor('#F7F8FA')
                .borderRadius(12)
                .border({ width: 1, color: '#E5E7EC' })
              Button($r('app.string.common_save'))
                .height(36)
                .backgroundColor('#EEF1F6')
                .fontColor('#17181C')
                .borderRadius(12)
                .enabled(this.notificationForwardingControlsEnabled())
                .onClick(() => {
                  void this.saveNotificationForwardingSessionKey();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text($r('app.string.settings_notification_forwarding_rate_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Text($r('app.string.settings_notification_forwarding_rate_sub'))
                .fontSize(12)
                .fontColor('#8A92A2')
              Row({ space: 10 }) {
                TextInput({
                  placeholder: '30',
                  text: this.notificationForwardingRateDraft,
                })
                  .enabled(this.notificationForwardingControlsEnabled())
                  .type(InputType.Number)
                  .onChange((value: string) => {
                    this.notificationForwardingRateDraft = value.replace(/[^0-9]/g, '');
                  })
                  .layoutWeight(1)
                  .backgroundColor('#F7F8FA')
                  .borderRadius(12)
                  .border({ width: 1, color: '#E5E7EC' })
                Button($r('app.string.common_save'))
                  .height(36)
                  .backgroundColor('#EEF1F6')
                  .fontColor('#17181C')
                  .borderRadius(12)
                  .enabled(this.notificationForwardingControlsEnabled())
                  .onClick(() => {
                    void this.saveNotificationForwardingRate();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Row() {
                Column({ space: 4 }) {
                  Text($r('app.string.settings_notification_forwarding_quiet_title'))
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#4D5563')
                  Text($r('app.string.settings_notification_forwarding_quiet_sub'))
                    .fontSize(12)
                    .fontColor('#8A92A2')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.notificationForwardingQuietHoursEnabled })
                  .selectedColor('#1D5DD8')
                  .enabled(this.notificationForwardingControlsEnabled())
                  .onChange((value: boolean) => {
                    void this.setNotificationForwardingQuietHoursChecked(value);
                  })
              }
              .width('100%')
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Text($r('app.string.settings_notification_forwarding_quiet_start'))
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#4D5563')
                  TextInput({
                    placeholder: '22:00',
                    text: this.notificationForwardingQuietStart,
                  })
                    .enabled(this.notificationForwardingControlsEnabled())
                    .onChange((value: string) => {
                      this.notificationForwardingQuietStart = value;
                    })
                    .backgroundColor('#F7F8FA')
                    .borderRadius(12)
                    .border({ width: 1, color: '#E5E7EC' })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Column({ space: 4 }) {
                  Text($r('app.string.settings_notification_forwarding_quiet_end'))
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#4D5563')
                  TextInput({
                    placeholder: '07:00',
                    text: this.notificationForwardingQuietEnd,
                  })
                    .enabled(this.notificationForwardingControlsEnabled())
                    .onChange((value: string) => {
                      this.notificationForwardingQuietEnd = value;
                    })
                    .backgroundColor('#F7F8FA')
                    .borderRadius(12)
                    .border({ width: 1, color: '#E5E7EC' })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              Button($r('app.string.common_save'))
                .height(36)
                .backgroundColor('#EEF1F6')
                .fontColor('#17181C')
                .borderRadius(12)
                .enabled(this.notificationForwardingControlsEnabled())
                .onClick(() => {
                  void this.saveNotificationForwardingQuietHours();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start)

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_photos'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_photos_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasPhotosPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasPhotosPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasPhotosPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasPhotosPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestPhotos();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_contacts'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_contacts_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasContactsPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasContactsPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasContactsPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasContactsPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestContacts();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_calendar'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_calendar_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.hasCalendarPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasCalendarPermission ? '#2F8C5A' : '#C8841A')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button(
              this.hasCalendarPermission ?
                this.resStr($r('app.string.settings_permission_manage')) :
                this.resStr($r('app.string.settings_permission_grant')),
            )
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .height(36)
              .backgroundColor('#1D5DD8')
              .fontColor(Color.White)
              .borderRadius(14)
              .onClick(() => {
                if (this.hasCalendarPermission) {
                  this.openAppSettings();
                } else {
                  void this.requestCalendar();
                }
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          if (this.motionAvailable) {
            Divider().strokeWidth(1).color('#E5E7EC').width('100%')

            Row() {
              Column({ space: 4 }) {
                Text($r('app.string.settings_permission_motion'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#17181C')
                Text($r('app.string.settings_permission_motion_sub'))
                  .fontSize(13)
                  .fontColor('#8A92A2')
                Text(this.hasMotionPermission ? this.resStr($r('app.string.settings_permission_granted')) : '—')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.hasMotionPermission ? '#2F8C5A' : '#C8841A')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button(
                this.hasMotionPermission ?
                  this.resStr($r('app.string.settings_permission_manage')) :
                  this.resStr($r('app.string.settings_permission_grant')),
              )
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .height(36)
                .backgroundColor('#1D5DD8')
                .fontColor(Color.White)
                .borderRadius(14)
                .onClick(() => {
                  if (this.hasMotionPermission) {
                    this.openAppSettings();
                  } else {
                    void this.requestMotion();
                  }
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
          }

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_sms'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_sms_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.resStr($r('app.string.settings_permission_unavailable_platform')))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })

          Divider().strokeWidth(1).color('#E5E7EC').width('100%')

          Row() {
            Column({ space: 4 }) {
              Text($r('app.string.settings_permission_call_log'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.settings_permission_call_log_sub'))
                .fontSize(13)
                .fontColor('#8A92A2')
              Text(this.resStr($r('app.string.settings_permission_unavailable_platform')))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#8A92A2')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader($r('app.string.settings_section_node'))

        Column({ space: 4 }) {
          Text($r('app.string.settings_name_label'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4D5563')
          TextInput({
            placeholder: $r('app.string.settings_name_label'),
            text: this.displayName,
          })
            .onChange((v: string) => {
              this.displayName = v;
              void this.nodeRuntime.setDisplayName(v);
            })
            .width('100%')
            .backgroundColor('#F7F8FA')
            .borderRadius(12)
            .border({ width: 1, color: '#E5E7EC' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text(this.resFmt1($r('app.string.settings_instance_id_label'), this.shortInstanceId(this.instanceId)))
          .fontSize(14)
          .fontFamily('monospace')
          .fontColor('#4D5563')
          .width('100%')
          .alignSelf(ItemAlign.Start)

        Text(this.resFmt1($r('app.string.settings_device_label'), this.nodeRuntime.getDeviceModel()))
          .fontSize(14)
          .fontColor('#4D5563')
          .width('100%')
          .alignSelf(ItemAlign.Start)

        Text(this.resFmt1($r('app.string.settings_version_label'), this.nodeRuntime.getVersion()))
          .fontSize(14)
          .fontColor('#4D5563')
          .width('100%')
          .alignSelf(ItemAlign.Start)

        Text($r('app.string.settings_platform_harmony'))
          .fontSize(12)
          .fontColor('#8A92A2')
          .width('100%')
          .alignSelf(ItemAlign.Start)

        Divider().strokeWidth(1).color('#E5E7EC').width('100%')

        Row() {
          Column({ space: 2 }) {
            Text($r('app.string.settings_clear_pairing'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#17181C')
            Text($r('app.string.settings_clear_pairing_subtitle'))
              .fontSize(14)
              .fontColor('#4D5563')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Blank()
          Button($r('app.string.settings_clear_pairing_button'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#1D5DD8')
            .fontColor('#FFFFFF')
            .borderRadius(14)
            .height(36)
            .onClick(async () => {
              await this.nodeRuntime.clearPairing();
              await this.reloadFromRuntime();
            })
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })

        Button($r('app.string.connect_run_onboarding_again'))
          .width('100%')
          .backgroundColor(Color.Transparent)
          .fontColor('#1D5DD8')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .borderRadius(12)
          .onClick(async () => {
            await this.nodeRuntime.setOnboardingCompleted(false);
          })

        Column().height(24)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .backgroundColor('#F7F8FA')
  }
}
