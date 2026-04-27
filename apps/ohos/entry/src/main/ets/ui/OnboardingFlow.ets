/**
 * Onboarding flow: Welcome → Gateway → Permissions → FinalCheck.
 * Matches Android flow: scan QR primary, advanced setup with SetupCode/Manual.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { promptAction } from '@kit.ArkUI';
import { notificationExtensionSubscription, notificationManager } from '@kit.NotificationKit';
import {
  decodeGatewaySetupCode,
  parseGatewayEndpoint,
  resolveScannedSetupCode,
  composeGatewayManualUrl,
} from '../common/GatewaySetupCode';
import type { GatewayEndpointConfig } from '../common/GatewaySetupCode';
import { NodeRuntime } from '../NodeRuntime';
import type { GatewayTrustPrompt } from '../NodeRuntime';
import { MotionHandler } from '../node/MotionHandler';
import { LocationMode } from '../LocationMode';
import { normalizeFingerprintForDisplay } from '../gateway/GatewayTls';

type OnboardingStep = 'welcome' | 'gateway' | 'permissions' | 'finalCheck';
type GatewayInputMode = 'setupCode' | 'manual';

@Component
export struct OnboardingFlow {
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime =
    AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

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

  private formatStepOf(): string {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return `Step ${this.stepIndex()} of 4`;
    }
    try {
      return ctx.resourceManager.getStringSync(
        $r('app.string.onboarding_step_of_fmt'),
        this.stepIndex(),
        4
      );
    } catch {
      return `Step ${this.stepIndex()} of 4`;
    }
  }

  @State step: OnboardingStep = 'welcome';
  @State setupCode: string = '';
  @State manualHost: string = '10.0.2.2';
  @State manualPort: string = '18789';
  @State manualTls: boolean = false;
  @State gatewayToken: string = '';
  @State gatewayPassword: string = '';
  @State gatewayInputMode: GatewayInputMode = 'setupCode';
  @State advancedOpen: boolean = false;
  @State gatewayError: string = '';
  @State gatewayUrl: string = '';
  @State gatewayEndpoint: GatewayEndpointConfig | null = null;
  @State attemptedConnect: boolean = false;
  @State pendingTrust: GatewayTrustPrompt | null = null;
  @State statusText: string = 'Offline';
  @State isConnected: boolean = false;
  @State remoteAddress: string = '';
  @State enableDiscovery: boolean = false;
  @State enableLocation: boolean = false;
  @State enableCamera: boolean = false;
  @State enableMicrophone: boolean = false;
  @State enableNotifications: boolean = false;
  @State enableNotificationListener: boolean = false;
  @State enablePhotos: boolean = false;
  @State enableContacts: boolean = false;
  @State enableCalendar: boolean = false;
  @State enableMotion: boolean = false;
  @State enableSms: boolean = false;
  @State enableCallLog: boolean = false;
  @State locationGranted: boolean = false;
  @State notificationsGranted: boolean = false;
  @State notificationListenerGranted: boolean = false;
  @State microphoneGranted: boolean = false;
  @State cameraGranted: boolean = false;
  @State photosGranted: boolean = false;
  @State contactsGranted: boolean = false;
  @State calendarGranted: boolean = false;
  @State motionGranted: boolean = false;
  /** Match Android: hide SMS / call log rows when capability is absent. */
  private readonly smsRowAvailable: boolean = false;
  private readonly callLogRowAvailable: boolean = false;
  private readonly motionRowAvailable: boolean = MotionHandler.isAvailable();

  aboutToAppear(): void {
    this.pendingTrust = this.nodeRuntime.getPendingGatewayTrustPrompt();
    this.nodeRuntime.setGatewayTrustListener((prompt) => {
      this.pendingTrust = prompt;
    });
    this.nodeRuntime.setStatusListener((s) => {
      // Defer to next tick to avoid stack overflow when notifyStatus is called
      // synchronously during connect (e.g. from WebSocket callbacks).
      setTimeout(() => {
        this.statusText = s.statusText;
        this.isConnected = s.isConnected;
        this.remoteAddress = s.remoteAddress;
      }, 0);
    });
    this.statusText = this.nodeRuntime.getStatusText();
    this.isConnected = this.nodeRuntime.getIsConnected();
    this.remoteAddress = this.nodeRuntime.getRemoteAddress();
    void this.loadSavedFeatureSelections();
    void this.refreshPermissionStates();
  }

  aboutToDisappear(): void {
    this.nodeRuntime.setGatewayTrustListener(null);
  }

  onPageShow(): void {
    void this.refreshPermissionStates();
  }

  private async doScanQr(): Promise<void> {
    const ctx =
      this.getUIContext().getHostContext() ??
      AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) return;
    this.gatewayError = '';
    try {
      const result = await scanBarcode.startScanForResult(ctx, {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: false,
        enableAlbum: true,
      });
      const raw = result?.originalValue?.trim();
      if (!raw) return;
      const code = resolveScannedSetupCode(raw);
      if (!code) {
        this.gatewayError = this.resStr($r('app.string.onboarding_qr_error_invalid_setup_code')) || 'Invalid setup code';
        return;
      }
      this.setupCode = code;
      this.gatewayInputMode = 'setupCode';
    } catch (_) {
      this.gatewayError = this.resStr($r('app.string.onboarding_scan_failed')) || 'Scan failed';
    }
  }

  private async loadSavedFeatureSelections(): Promise<void> {
    this.enableCamera = await this.nodeRuntime.getCameraEnabled();
    this.enableLocation = (await this.nodeRuntime.getLocationMode()) !== LocationMode.Off;
  }

  private async persistSelectedFeatureSettings(): Promise<void> {
    await Promise.all([
      this.nodeRuntime.setCameraEnabled(this.enableCamera),
      this.nodeRuntime.setLocationMode(this.enableLocation ? LocationMode.WhileUsing : LocationMode.Off),
    ]);
  }

  private async goNext(): Promise<void> {
    if (this.step === 'welcome') {
      this.step = 'gateway';
      return;
    }
    if (this.step === 'gateway') {
      if (this.gatewayInputMode === 'setupCode') {
        const decoded = decodeGatewaySetupCode(this.setupCode);
        if (!decoded) {
          this.gatewayError = this.resStr($r('app.string.onboarding_error_scan_qr_first')) || 'Scan QR first, or use advanced setup.';
          return;
        }
        const ep = parseGatewayEndpoint(decoded.url);
        if (!ep) {
          this.gatewayError = this.resStr($r('app.string.onboarding_error_setup_code_invalid_url')) || 'Gateway URL in setup code is invalid.';
          return;
        }
        this.gatewayUrl = decoded.url;
        this.gatewayEndpoint = ep;
        this.gatewayToken = decoded.token ?? '';
        this.gatewayPassword = decoded.password ?? '';
      } else {
        const manualUrl = composeGatewayManualUrl(
          this.manualHost,
          this.manualPort,
          this.manualTls
        );
        const ep = manualUrl ? parseGatewayEndpoint(manualUrl) : null;
        if (!ep) {
          this.gatewayError = this.resStr($r('app.string.onboarding_error_manual_invalid_endpoint')) || 'Manual endpoint is invalid.';
          return;
        }
        this.gatewayUrl = ep.displayUrl;
        this.gatewayEndpoint = ep;
      }
      this.gatewayError = '';
      this.step = 'permissions';
      return;
    }
    if (this.step === 'permissions') {
      await this.persistSelectedFeatureSettings();
      this.step = 'finalCheck';
      return;
    }
  }

  private goBack(): void {
    if (this.step === 'gateway') this.step = 'welcome';
    else if (this.step === 'permissions') this.step = 'gateway';
    else if (this.step === 'finalCheck') this.step = 'permissions';
  }

  private async doConnect(): Promise<void> {
    if (!this.gatewayEndpoint) {
      this.gatewayError = this.resStr($r('app.string.onboarding_error_invalid_gateway_url')) || 'Gateway URL is invalid.';
      this.step = 'gateway';
      return;
    }
    this.attemptedConnect = true;
    this.gatewayError = '';
    try {
      await this.nodeRuntime.saveManualConfig(
        this.gatewayEndpoint.host,
        this.gatewayEndpoint.port,
        this.gatewayEndpoint.tls,
        this.gatewayToken.trim(),
        this.gatewayPassword.trim()
      );
      await this.nodeRuntime.connect(
        this.gatewayEndpoint.host,
        this.gatewayEndpoint.port,
        this.gatewayEndpoint.tls,
        this.gatewayToken.trim(),
        this.gatewayPassword.trim()
      );
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      const stack = e instanceof Error && e.stack ? e.stack : '';
      hilog.error(0x0000, 'OnboardingFlow', 'doConnect failed: %{public}s', msg);
      if (stack) {
        hilog.error(0x0000, 'OnboardingFlow', 'stack: %{public}s', stack);
      }
      this.gatewayError = msg;
    }
  }

  private async doFinish(): Promise<void> {
    await this.persistSelectedFeatureSettings();
    await this.requestSelectedPermissions();
    await this.nodeRuntime.setOnboardingCompleted(true);
  }

  private permissionGranted(permissionNames: Permissions[]): boolean {
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

  private permissionsGranted(permissionNames: Permissions[]): boolean {
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

  private async requestRuntimePermissions(permissionNames: Permissions[]): Promise<boolean> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return false;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const result = await at.requestPermissionsFromUser(ctx, permissionNames);
      return result.authResults.length > 0 &&
        result.authResults.some((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
    } catch {
      return this.permissionGranted(permissionNames);
    }
  }

  private async refreshPermissionStates(): Promise<void> {
    this.locationGranted = this.permissionGranted([
      'ohos.permission.APPROXIMATELY_LOCATION',
      'ohos.permission.LOCATION',
    ]);
    this.notificationsGranted = await this.readNotificationsGranted();
    this.notificationListenerGranted = await this.readNotificationListenerGranted();
    this.microphoneGranted = this.permissionGranted(['ohos.permission.MICROPHONE']);
    this.cameraGranted = this.permissionGranted(['ohos.permission.CAMERA']);
    this.photosGranted = this.permissionGranted(['ohos.permission.READ_IMAGEVIDEO']);
    this.contactsGranted = this.permissionsGranted([
      'ohos.permission.READ_CONTACTS',
      'ohos.permission.WRITE_CONTACTS',
    ]);
    this.calendarGranted = this.permissionsGranted([
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
    ]);
    this.motionGranted = this.permissionsGranted([
      'ohos.permission.ACTIVITY_MOTION',
      'ohos.permission.ACCELEROMETER',
    ]);
  }

  private async readNotificationsGranted(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch {
      return false;
    }
  }

  private async readNotificationListenerGranted(): Promise<boolean> {
    try {
      return await notificationExtensionSubscription.isUserGranted();
    } catch {
      return false;
    }
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

  private async requestSelectedPermissions(): Promise<void> {
    if (this.enableLocation) {
      await this.requestRuntimePermissions([
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION',
      ]);
    }
    if (this.enableNotifications) {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx) {
        try {
          await notificationManager.requestEnableNotification(ctx);
        } catch {
          // best-effort
        }
      }
    }
    if (this.enableNotificationListener) {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx) {
        try {
          await notificationExtensionSubscription.openSubscriptionSettings(ctx);
        } catch {
          this.openAppSettings();
        }
      }
    }
    if (this.enableMicrophone) {
      await this.requestRuntimePermissions(['ohos.permission.MICROPHONE']);
    }
    if (this.enableCamera) {
      await this.requestRuntimePermissions(['ohos.permission.CAMERA']);
    }
    if (this.enablePhotos) {
      await this.requestRuntimePermissions(['ohos.permission.READ_IMAGEVIDEO']);
    }
    if (this.enableContacts) {
      await this.requestRuntimePermissions([
        'ohos.permission.READ_CONTACTS',
        'ohos.permission.WRITE_CONTACTS',
      ]);
    }
    if (this.enableCalendar) {
      await this.requestRuntimePermissions([
        'ohos.permission.READ_CALENDAR',
        'ohos.permission.WRITE_CALENDAR',
      ]);
    }
    if (this.motionRowAvailable && this.enableMotion) {
      await this.requestRuntimePermissions([
        'ohos.permission.ACTIVITY_MOTION',
        'ohos.permission.ACCELEROMETER',
      ]);
    }
    await this.refreshPermissionStates();
  }

  private resolvedEndpointFromSetupCode(): string {
    const decoded = decodeGatewaySetupCode(this.setupCode);
    if (!decoded) return '';
    const ep = parseGatewayEndpoint(decoded.url);
    return ep?.displayUrl ?? '';
  }

  private resolvedEndpointFromManual(): string {
    const url = composeGatewayManualUrl(
      this.manualHost,
      this.manualPort,
      this.manualTls
    );
    const ep = url ? parseGatewayEndpoint(url) : null;
    return ep?.displayUrl ?? '';
  }

  /** Mirrors Android `GatewayDiagnostics.gatewayStatusForDisplay`. */
  private gatewayStatusForDisplay(raw: string): string {
    const s = raw.trim();
    return s.length > 0 ? s : 'Offline';
  }

  private gatewayStatusHasDiagnostics(statusText: string): boolean {
    const lower = this.gatewayStatusForDisplay(statusText).toLowerCase();
    return lower !== 'offline' && !lower.includes('connecting');
  }

  private gatewayStatusLooksLikePairing(statusText: string): boolean {
    const lower = this.gatewayStatusForDisplay(statusText).toLowerCase();
    return lower.includes('pair') || lower.includes('approve');
  }

  private connectedDetailLine(): string {
    const addr = this.remoteAddress.trim();
    if (addr.length > 0) {
      return addr;
    }
    return this.resStr($r('app.string.onboarding_review_gateway_fallback')) || 'gateway';
  }

  private formatOpenClawHarmonyOsVersion(): string {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    const ver = this.nodeRuntime.getVersion();
    if (!ctx) {
      return `OpenClaw HarmonyOS ${ver}`;
    }
    try {
      return ctx.resourceManager.getStringSync($r('app.string.onboarding_openclaw_harmonyos_diag_fmt'), ver);
    } catch {
      return `OpenClaw HarmonyOS ${ver}`;
    }
  }

  private buildGatewayDiagnosticsReport(gatewayAddress: string, statusLabel: string): string {
    const device = this.nodeRuntime.getDeviceModel();
    const ver = this.nodeRuntime.getVersion();
    const endpoint = gatewayAddress.trim().length > 0 ? gatewayAddress.trim() : 'unknown';
    const status = statusLabel.trim().length > 0 ? statusLabel.trim() : 'Offline';
    return (
      'Help diagnose this OpenClaw HarmonyOS gateway connection failure.\n\n' +
      'Please:\n' +
      '- pick one route only: same machine, same LAN, Tailscale, or public URL\n' +
      '- classify this as pairing/auth, TLS trust, wrong advertised route, wrong address/port, or gateway down\n' +
      '- quote the exact app status/error below\n' +
      '- tell me whether `openclaw devices list` should show a pending pairing request\n' +
      '- if more signal is needed, ask for `openclaw qr --json`, `openclaw devices list`, and `openclaw nodes status`\n' +
      '- give the next exact command or tap\n\n' +
      'Debug info:\n' +
      '- screen: onboarding final check\n' +
      `- app version: OpenClaw HarmonyOS ${ver}\n` +
      `- device: ${device}\n` +
      `- gateway address: ${endpoint}\n` +
      `- status/error: ${status}\n`
    );
  }

  private async copyDiagnosticsReport(): Promise<void> {
    const gatewayAddr = this.gatewayEndpoint?.displayUrl ?? '';
    const statusLabel = this.gatewayStatusForDisplay(this.statusText);
    const report = this.buildGatewayDiagnosticsReport(gatewayAddr, statusLabel);
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, report);
      const sys = pasteboard.getSystemPasteboard();
      await sys.setData(data);
      await promptAction.showToast({
        message: this.resStr($r('app.string.onboarding_copy_report_toast')) || 'Copied gateway diagnostics',
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0000, 'OnboardingFlow', 'copyDiagnosticsReport: %{public}s', msg);
      try {
        await promptAction.showToast({ message: 'Copy failed' });
      } catch (_) {
        // Best-effort UI; clipboard path already failed.
      }
    }
  }

  private permissionStatusLine(statusOverride: string, osGranted: boolean): string {
    if (statusOverride.length > 0) {
      return statusOverride;
    }
    return osGranted ?
      (this.resStr($r('app.string.onboarding_perm_granted')) || 'Granted') :
      (this.resStr($r('app.string.onboarding_perm_not_granted')) || 'Not granted');
  }

  private permissionStatusColor(statusOverride: string, osGranted: boolean): string {
    if (statusOverride.length > 0) {
      return '#8A92A2';
    }
    return osGranted ? '#2F8C5A' : '#C8841A';
  }

  private applyPermToggle(key: number, v: boolean): void {
    switch (key) {
      case 0:
        this.enableDiscovery = v;
        break;
      case 1:
        this.enableLocation = v;
        break;
      case 2:
        this.enableNotifications = v;
        break;
      case 3:
        this.enableNotificationListener = v;
        break;
      case 4:
        this.enableMicrophone = v;
        break;
      case 5:
        this.enableCamera = v;
        break;
      case 6:
        this.enablePhotos = v;
        break;
      case 7:
        this.enableContacts = v;
        break;
      case 8:
        this.enableCalendar = v;
        break;
      case 9:
        this.enableMotion = v;
        break;
      case 10:
        this.enableSms = v;
        break;
      case 11:
        this.enableCallLog = v;
        break;
      default:
        break;
    }
  }

  private reviewMethodLabel(): string {
    if (this.gatewayInputMode === 'setupCode') {
      return this.resStr($r('app.string.onboarding_review_method_qr_setup_code'));
    }
    return this.resStr($r('app.string.connect_method_manual'));
  }

  private reviewGatewayAddress(): string {
    const u = this.gatewayEndpoint?.displayUrl ?? '';
    return u.length > 0 ? u : 'Invalid gateway URL';
  }

  private reviewSummaryLabelUpper(res: Resource): string {
    return this.resStr(res).toUpperCase();
  }

  private enabledPermissionsSummary(): string {
    const parts: string[] = [];
    if (this.enableDiscovery) {
      parts.push(this.resStr($r('app.string.onboarding_perm_gateway_discovery_title')));
    }
    if (this.enableLocation) {
      parts.push(this.resStr($r('app.string.onboarding_perm_location_title')));
    }
    if (this.enableNotifications) {
      parts.push(this.resStr($r('app.string.onboarding_perm_notifications_title')));
    }
    if (this.enableNotificationListener) {
      parts.push(this.resStr($r('app.string.onboarding_perm_notification_listener_title')));
    }
    if (this.enableMicrophone) {
      parts.push(this.resStr($r('app.string.onboarding_perm_microphone_title')));
    }
    if (this.enableCamera) {
      parts.push(this.resStr($r('app.string.onboarding_perm_camera_title')));
    }
    if (this.enablePhotos) {
      parts.push(this.resStr($r('app.string.onboarding_perm_photos_title')));
    }
    if (this.enableContacts) {
      parts.push(this.resStr($r('app.string.onboarding_perm_contacts_title')));
    }
    if (this.enableCalendar) {
      parts.push(this.resStr($r('app.string.onboarding_perm_calendar_title')));
    }
    if (this.motionRowAvailable && this.enableMotion) {
      parts.push(this.resStr($r('app.string.onboarding_perm_motion_title')));
    }
    if (this.smsRowAvailable && this.enableSms) {
      parts.push(this.resStr($r('app.string.onboarding_perm_sms_title')));
    }
    if (this.callLogRowAvailable && this.enableCallLog) {
      parts.push(this.resStr($r('app.string.onboarding_perm_call_log_title')));
    }
    return parts.length > 0 ?
      parts.filter((p) => p.length > 0).join(', ') :
      (this.resStr($r('app.string.onboarding_perm_none_selected')) || 'No permissions selected');
  }

  private stepIndex(): number {
    return this.step === 'welcome' ? 1 : this.step === 'gateway' ? 2 : this.step === 'permissions' ? 3 : 4;
  }

  @Builder
  WelcomeFeatureCard(iconRes: Resource, titleRes: Resource, subtitleRes: Resource, accentColor: string, accentSoftBg: string) {
    Row({ space: 14 }) {
      Column() {
        SymbolGlyph(iconRes)
          .fontSize(22)
          .fontColor([accentColor])
      }
      .width(42)
      .height(42)
      .borderRadius(11)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(accentSoftBg)
      Column({ space: 2 }) {
        Text(titleRes)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
        Text(subtitleRes)
          .fontSize(14)
          .fontColor('#4D5563')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E5E7EC' })
  }

  @Builder
  PermissionSectionHeader(titleRes: Resource) {
    Text(this.resStr(titleRes).toUpperCase())
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor('#1D5DD8')
      .letterSpacing(1.2)
      .margin({ top: 8 })
  }

  @Builder
  PermissionToggleRow(
    titleRes: Resource,
    subtitleRes: Resource,
    osGranted: boolean,
    rowEnabled: boolean,
    statusOverride: string,
    isOn: boolean,
    toggleKey: number,
  ) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(titleRes)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
        Text(subtitleRes)
          .fontSize(14)
          .fontColor('#4D5563')
        Text(this.permissionStatusLine(statusOverride, osGranted))
          .fontSize(12)
          .fontColor(this.permissionStatusColor(statusOverride, osGranted))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .enabled(rowEnabled)
        .onChange((v: boolean) => {
          this.applyPermToggle(toggleKey, v);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ReviewSummaryCard(iconRes: Resource, labelUpper: string, valueText: string, accentColor: string, accentSoftBg: string) {
    Row({ space: 14 }) {
      Column() {
        SymbolGlyph(iconRes)
          .fontSize(22)
          .fontColor([accentColor])
      }
      .width(42)
      .height(42)
      .borderRadius(11)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(accentSoftBg)
      Column({ space: 2 }) {
        Text(labelUpper)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4D5563')
          .letterSpacing(0.8)
        Text(valueText)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E5E7EC' })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  ReviewCommandBlock(command: string) {
    Row() {
      Column()
        .width(3)
        .constraintSize({ minHeight: 40 })
        .backgroundColor('#3FC97A')
        .borderRadius(2)
      Text(command)
        .fontSize(14)
        .fontFamily('monospace')
        .fontColor('#E8EAEE')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .layoutWeight(1)
    }
    .width('100%')
    .backgroundColor('#15171B')
    .borderRadius(12)
    .border({ width: 1, color: '#2B2E35' })
  }

  @Builder
  StepRail() {
    Column({ space: 10 }) {
      Divider().color('#E5E7EC')
      Row({ space: 4 }) {
        this.StepRailItem(1)
        this.StepRailItem(2)
        this.StepRailItem(3)
        this.StepRailItem(4)
      }
      .width('100%')
      Divider().color('#E5E7EC')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  StepRailItem(index: number) {
    Column({ space: 4 }) {
      Row()
        .width('100%')
        .height(5)
        .borderRadius(999)
        .backgroundColor(
          index < this.stepIndex() ? '#2F8C5A' :
          index === this.stepIndex() ? '#1D5DD8' : '#E5E7EC'
        )
      Text(
        index === 1 ? $r('app.string.onboarding_step_welcome_label') :
        index === 2 ? $r('app.string.onboarding_step_gateway_label') :
        index === 3 ? $r('app.string.onboarding_step_permissions_label') :
        $r('app.string.onboarding_step_final_check_label')
      )
        .fontSize(11)
        .fontWeight(index === this.stepIndex() ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(index === this.stepIndex() ? '#1D5DD8' : '#4D5563')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Column({ space: 8 }) {
        Text($r('app.string.onboarding_first_run_kicker'))
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D5DD8')
        Text($r('app.string.onboarding_title_mobile_setup'))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17181C')
        Text(this.formatStepOf())
          .fontSize(12)
          .fontColor('#1D5DD8')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 12 })

      this.StepRail()

      Scroll() {
        Column({ space: 16 }) {
          if (this.step === 'welcome') {
            this.WelcomeStep();
          } else if (this.step === 'gateway') {
            this.GatewayStep();
          } else if (this.step === 'permissions') {
            this.PermissionsStep();
          } else {
            this.FinalStep();
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)

        Row({ space: 10 }) {
          Button($r('app.string.common_back'))
            .width(64)
            .height(52)
            .enabled(this.step !== 'welcome')
            .backgroundColor('#F6F7FA')
            .fontColor(this.step !== 'welcome' ? '#4D5563' : '#8A92A2')
            .onClick(() => this.goBack())

          if (this.step === 'welcome' || this.step === 'gateway' || this.step === 'permissions') {
            Button($r('app.string.common_next'))
              .layoutWeight(1)
              .height(52)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#1D5DD8')
              .onClick(() => {
                void this.goNext();
              })
          } else if (this.step === 'finalCheck') {
            if (this.isConnected) {
              Button($r('app.string.common_finish'))
                .layoutWeight(1)
                .height(52)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#1D5DD8')
                .onClick(() => this.doFinish())
            } else {
              Button($r('app.string.common_connect'))
                .layoutWeight(1)
                .height(52)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#1D5DD8')
                .onClick(() => this.doConnect())
            }
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 8 })
      }
      .width('100%')
      .height('100%')
      .padding(20)
      .backgroundColor('#F7F8FA')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)

      if (this.pendingTrust !== null) {
        Column() {
          Column({ space: 14 }) {
            Text($r('app.string.connect_tls_trust_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#17181C')
            Text($r('app.string.connect_tls_trust_body'))
              .fontSize(14)
              .fontColor('#4D5563')
            Text(normalizeFingerprintForDisplay(this.pendingTrust?.fingerprintSha256 ?? ''))
              .fontSize(13)
              .fontFamily('monospace')
              .fontColor('#17181C')
              .padding(12)
              .width('100%')
              .backgroundColor('#F6F7FA')
              .borderRadius(12)
              .border({ width: 1, color: '#E5E7EC' })
            Row({ space: 10 }) {
              Button($r('app.string.common_cancel'))
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#F6F7FA')
                .fontColor('#4D5563')
                .onClick(() => {
                  this.nodeRuntime.declineGatewayTrustPrompt();
                })
              Button($r('app.string.connect_tls_trust_accept'))
                .layoutWeight(1)
                .height(44)
                .backgroundColor('#1D5DD8')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  void this.nodeRuntime.acceptGatewayTrustPrompt();
                })
            }
            .width('100%')
          }
          .width('88%')
          .padding(20)
          .backgroundColor('#FFFFFF')
          .borderRadius(20)
          .border({ width: 1, color: '#E5E7EC' })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(23, 24, 28, 0.45)')
        .justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  WelcomeStep() {
    Column({ space: 10 }) {
      this.WelcomeFeatureCard(
        $r('sys.symbol.ohos_wifi'),
        $r('app.string.onboarding_welcome_card_gateway_title'),
        $r('app.string.onboarding_welcome_card_gateway_subtitle'),
        '#1D5DD8',
        'rgba(29, 93, 216, 0.1)'
      )
      this.WelcomeFeatureCard(
        $r('sys.symbol.gearshape_fill'),
        $r('app.string.onboarding_welcome_card_permissions_title'),
        $r('app.string.onboarding_welcome_card_permissions_subtitle'),
        '#7C5AC7',
        'rgba(124, 90, 199, 0.1)'
      )
      this.WelcomeFeatureCard(
        $r('sys.symbol.message_on_message_fill'),
        $r('app.string.onboarding_welcome_card_features_title'),
        $r('app.string.onboarding_welcome_card_features_subtitle'),
        '#2F8C5A',
        'rgba(47, 140, 90, 0.1)'
      )
      this.WelcomeFeatureCard(
        $r('sys.symbol.checkmark_circle_fill'),
        $r('app.string.onboarding_welcome_card_verify_title'),
        $r('app.string.onboarding_welcome_card_verify_subtitle'),
        '#C8841A',
        'rgba(200, 132, 26, 0.1)'
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  GatewayStep() {
    Column({ space: 12 }) {
      Text($r('app.string.onboarding_gateway_section_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17181C')

      Column({ space: 8 }) {
        Text($r('app.string.onboarding_gateway_qr_primary_hint'))
          .fontSize(14)
          .fontColor('#4D5563')
        Row() {
          Column()
            .width(3)
            .height(42)
            .backgroundColor('#3FC97A')
            .borderRadius(2)
          Text('openclaw qr')
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#E8EAEE')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .layoutWeight(1)
        }
        .width('100%')
        .backgroundColor('#15171B')
        .borderRadius(12)
        .border({ width: 1, color: '#2B2E35' })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 10 })
      .border({ width: { left: 2 }, color: 'rgba(29,93,216,0.4)' })

      Button($r('app.string.onboarding_scan_qr_button'))
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .backgroundColor('#1D5DD8')
        .onClick(() => this.doScanQr())

      if (this.resolvedEndpointFromSetupCode().length > 0) {
        Text($r('app.string.onboarding_qr_captured_review_endpoint'))
          .fontSize(14)
          .fontColor('#2F8C5A')
        Column({ space: 4 }) {
          Divider().color('#E5E7EC')
          Text($r('app.string.onboarding_resolved_endpoint_header'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4D5563')
          Text(this.resolvedEndpointFromSetupCode())
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#17181C')
          Divider().color('#E5E7EC')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Divider().color('#E5E7EC')

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.onboarding_advanced_setup_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
          Text($r('app.string.onboarding_advanced_setup_subtitle'))
            .fontSize(12)
            .fontColor('#4D5563')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          this.advancedOpen = !this.advancedOpen;
        })
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F6F7FA')
      .borderRadius(12)
      .border({ width: 1, color: '#D6DAE2' })

      if (this.advancedOpen) {
        Column({ space: 12 }) {
          Text($r('app.string.onboarding_manual_setup_commands_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
          Text($r('app.string.onboarding_run_on_gateway_host'))
            .fontSize(14)
            .fontColor('#4D5563')
          Text('openclaw qr --setup-code-only')
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#E8EAEE')
            .backgroundColor('#15171B')
            .padding(12)
            .borderRadius(12)
          Text('openclaw qr --json')
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#E8EAEE')
            .backgroundColor('#15171B')
            .padding(12)
            .borderRadius(12)
          Text($r('app.string.onboarding_manual_setup_json_hint'))
            .fontSize(14)
            .fontColor('#4D5563')
          Text($r('app.string.onboarding_manual_setup_auto_discovery_hint'))
            .fontSize(14)
            .fontColor('#4D5563')

          Row({ space: 8 }) {
            Button($r('app.string.connect_method_setup_code'))
              .layoutWeight(1)
              .height(40)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.gatewayInputMode === 'setupCode' ? '#1D5DD8' : '#F6F7FA')
              .onClick(() => {
                this.gatewayInputMode = 'setupCode';
                this.gatewayError = '';
              })
            Button($r('app.string.connect_method_manual'))
              .layoutWeight(1)
              .height(40)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.gatewayInputMode === 'manual' ? '#1D5DD8' : '#F6F7FA')
              .onClick(() => {
                this.gatewayInputMode = 'manual';
                this.gatewayError = '';
              })
          }

          if (this.gatewayInputMode === 'setupCode') {
            Text($r('app.string.onboarding_setup_code_label'))
              .fontSize(12)
              .fontColor('#4D5563')
            TextInput({ placeholder: $r('app.string.onboarding_setup_code_placeholder'), text: this.setupCode })
              .onChange((v: string) => {
                this.setupCode = v;
                this.gatewayError = '';
              })
              .height(80)
            if (this.resolvedEndpointFromSetupCode().length > 0) {
              Column({ space: 4 }) {
                Divider().color('#E5E7EC')
                Text($r('app.string.onboarding_resolved_endpoint_header'))
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#4D5563')
                Text(this.resolvedEndpointFromSetupCode())
                  .fontSize(14)
                  .fontFamily('monospace')
                  .fontColor('#17181C')
                Divider().color('#E5E7EC')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          } else {
            Row({ space: 8 }) {
              Button($r('app.string.onboarding_quickfill_android_emulator'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .backgroundColor('#ECF3FF')
                .fontColor('#1D5DD8')
                .onClick(() => {
                  this.manualHost = '10.0.2.2';
                  this.manualPort = '18789';
                  this.manualTls = false;
                })
              Button($r('app.string.onboarding_quickfill_localhost'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .backgroundColor('#ECF3FF')
                .fontColor('#1D5DD8')
                .onClick(() => {
                  this.manualHost = '127.0.0.1';
                  this.manualPort = '18789';
                  this.manualTls = false;
                })
            }
            Text($r('app.string.onboarding_manual_host_label'))
              .fontSize(12)
              .fontColor('#4D5563')
            TextInput({ placeholder: $r('app.string.onboarding_manual_host_placeholder'), text: this.manualHost })
              .onChange((v) => { this.manualHost = v; this.gatewayError = ''; })
            Text($r('app.string.onboarding_manual_port_label'))
              .fontSize(12)
              .fontColor('#4D5563')
            TextInput({ placeholder: $r('app.string.onboarding_manual_port_placeholder'), text: this.manualPort })
              .type(InputType.Number)
              .onChange((v) => { this.manualPort = v; this.gatewayError = ''; })
            Column({ space: 2 }) {
              Text($r('app.string.onboarding_use_tls'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.onboarding_use_tls_subtitle'))
                .fontSize(12)
                .fontColor('#4D5563')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Row() {
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.manualTls })
                .onChange((v: boolean) => { this.manualTls = v; })
            }
            .width('100%')
            Text($r('app.string.onboarding_token_optional_label'))
              .fontSize(12)
              .fontColor('#4D5563')
            TextInput({ placeholder: $r('app.string.onboarding_token_optional_placeholder'), text: this.gatewayToken })
              .onChange((v) => { this.gatewayToken = v; })
            Text($r('app.string.onboarding_password_optional_label'))
              .fontSize(12)
              .fontColor('#4D5563')
            TextInput({ placeholder: $r('app.string.onboarding_password_optional_placeholder'), text: this.gatewayPassword })
              .type(InputType.Password)
              .onChange((v: string) => { this.gatewayPassword = v; })
            if (this.resolvedEndpointFromManual().length > 0) {
              Column({ space: 4 }) {
                Divider().color('#E5E7EC')
                Text($r('app.string.onboarding_resolved_endpoint_header'))
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#4D5563')
                Text(this.resolvedEndpointFromManual())
                  .fontSize(14)
                  .fontFamily('monospace')
                  .fontColor('#17181C')
                Divider().color('#E5E7EC')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }
        }
      }

      if (this.gatewayError.length > 0) {
        Text(this.gatewayError)
          .fontSize(12)
          .fontColor('#C8841A')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PermissionsStep() {
    Column({ space: 12 }) {
      Text($r('app.string.onboarding_permissions_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17181C')
      Text($r('app.string.onboarding_permissions_intro'))
        .fontSize(14)
        .fontColor('#4D5563')

      this.PermissionSectionHeader($r('app.string.onboarding_section_system'))
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_gateway_discovery_title'),
        $r('app.string.onboarding_perm_gateway_discovery_subtitle'),
        false,
        true,
        '',
        this.enableDiscovery,
        0
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_location_title'),
        $r('app.string.onboarding_perm_location_subtitle'),
        this.locationGranted,
        true,
        '',
        this.enableLocation,
        1
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_notifications_title'),
        $r('app.string.onboarding_perm_notifications_subtitle'),
        this.notificationsGranted,
        true,
        '',
        this.enableNotifications,
        2
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_notification_listener_title'),
        $r('app.string.onboarding_perm_notification_listener_subtitle'),
        this.notificationListenerGranted,
        true,
        '',
        this.enableNotificationListener,
        3
      )

      this.PermissionSectionHeader($r('app.string.onboarding_section_media'))
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_microphone_title'),
        $r('app.string.onboarding_perm_microphone_subtitle'),
        this.microphoneGranted,
        true,
        '',
        this.enableMicrophone,
        4
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_camera_title'),
        $r('app.string.onboarding_perm_camera_subtitle'),
        this.cameraGranted,
        true,
        '',
        this.enableCamera,
        5
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_photos_title'),
        $r('app.string.onboarding_perm_photos_subtitle'),
        this.photosGranted,
        true,
        '',
        this.enablePhotos,
        6
      )

      this.PermissionSectionHeader($r('app.string.onboarding_section_personal_data'))
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_contacts_title'),
        $r('app.string.onboarding_perm_contacts_subtitle'),
        this.contactsGranted,
        true,
        '',
        this.enableContacts,
        7
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_calendar_title'),
        $r('app.string.onboarding_perm_calendar_subtitle'),
        this.calendarGranted,
        true,
        '',
        this.enableCalendar,
        8
      )
      Divider().color('#E5E7EC')
      this.PermissionToggleRow(
        $r('app.string.onboarding_perm_motion_title'),
        $r('app.string.onboarding_perm_motion_subtitle'),
        this.motionGranted,
        this.motionRowAvailable,
        this.motionRowAvailable ? '' : (this.resStr($r('app.string.onboarding_perm_unavailable_on_device')) || ''),
        this.enableMotion,
        9
      )
      if (this.smsRowAvailable) {
        Divider().color('#E5E7EC')
        this.PermissionToggleRow(
          $r('app.string.onboarding_perm_sms_title'),
          $r('app.string.onboarding_perm_sms_subtitle'),
          false,
          true,
          '',
          this.enableSms,
          10
        )
      }
      if (this.callLogRowAvailable) {
        Divider().color('#E5E7EC')
        this.PermissionToggleRow(
          $r('app.string.onboarding_perm_call_log_title'),
          $r('app.string.onboarding_perm_call_log_subtitle'),
          false,
          true,
          '',
          this.enableCallLog,
          11
        )
      }

      Text($r('app.string.onboarding_permissions_footer'))
        .fontSize(14)
        .fontColor('#4D5563')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FinalStep() {
    Column({ space: 10 }) {
      Text($r('app.string.onboarding_review_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17181C')

      this.ReviewSummaryCard(
        $r('sys.symbol.link'),
        this.reviewSummaryLabelUpper($r('app.string.onboarding_review_method_label')),
        this.reviewMethodLabel(),
        '#1D5DD8',
        'rgba(29, 93, 216, 0.1)'
      )
      this.ReviewSummaryCard(
        $r('sys.symbol.cloud_fill'),
        this.reviewSummaryLabelUpper($r('app.string.onboarding_review_gateway_label')),
        this.reviewGatewayAddress(),
        '#7C5AC7',
        'rgba(124, 90, 199, 0.1)'
      )
      this.ReviewSummaryCard(
        $r('sys.symbol.lock_shield_fill'),
        this.reviewSummaryLabelUpper($r('app.string.onboarding_review_permissions_card_label')),
        this.enabledPermissionsSummary(),
        '#2F8C5A',
        'rgba(47, 140, 90, 0.1)'
      )

      if (!this.attemptedConnect) {
        Row({ space: 12 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.ohos_wifi'))
              .fontSize(22)
              .fontColor(['#1D5DD8'])
          }
          .width(42)
          .height(42)
          .borderRadius(11)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(29, 93, 216, 0.1)')
          Text($r('app.string.onboarding_review_connect_hint'))
            .fontSize(14)
            .fontColor('#1D5DD8')
            .layoutWeight(1)
        }
        .width('100%')
        .padding(14)
        .backgroundColor('rgba(29, 93, 216, 0.08)')
        .borderRadius(14)
        .border({ width: 1, color: 'rgba(29, 93, 216, 0.2)' })
        .alignItems(VerticalAlign.Center)
      } else if (this.isConnected) {
        Row({ space: 12 }) {
          Column() {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(22)
              .fontColor(['#2F8C5A'])
          }
          .width(42)
          .height(42)
          .borderRadius(11)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(47, 140, 90, 0.1)')
          Column({ space: 2 }) {
            Text($r('app.string.onboarding_review_connected_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2F8C5A')
            Text(this.connectedDetailLine())
              .fontSize(14)
              .fontColor('rgba(47, 140, 90, 0.85)')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(14)
        .backgroundColor('rgba(47, 140, 90, 0.12)')
        .borderRadius(14)
        .border({ width: 1, color: 'rgba(47, 140, 90, 0.2)' })
        .alignItems(VerticalAlign.Center)
      } else {
        Column({ space: 10 }) {
          Row({ space: 12 }) {
            Column() {
              SymbolGlyph($r('sys.symbol.link'))
                .fontSize(22)
                .fontColor(['#C8841A'])
            }
            .width(42)
            .height(42)
            .borderRadius(11)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(200, 132, 26, 0.1)')
            Column({ space: 2 }) {
              Text(
                this.gatewayStatusLooksLikePairing(this.statusText) ?
                  $r('app.string.onboarding_review_pairing_required_title') :
                  $r('app.string.onboarding_connection_failed_title')
              )
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#C8841A')
              Text(
                this.gatewayStatusLooksLikePairing(this.statusText) ?
                  $r('app.string.onboarding_pairing_failed_body') :
                  $r('app.string.onboarding_connection_failed_body')
              )
                .fontSize(14)
                .fontColor('#4D5563')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.gatewayStatusHasDiagnostics(this.statusText)) {
            Text($r('app.string.onboarding_diagnostics_error_label'))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#4D5563')
            Text(this.gatewayStatusForDisplay(this.statusText))
              .fontSize(14)
              .fontFamily('monospace')
              .fontColor('#E8EAEE')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .width('100%')
              .backgroundColor('#15171B')
              .borderRadius(12)
              .border({ width: 1, color: '#2B2E35' })
            Text(this.formatOpenClawHarmonyOsVersion())
              .fontSize(12)
              .fontColor('#4D5563')
            Button(this.resStr($r('app.string.onboarding_copy_report_button')) || 'Copy Report for Claw')
              .width('100%')
              .height(48)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#C8841A')
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: 'rgba(200, 132, 26, 0.3)' })
              .onClick(() => {
                void this.copyDiagnosticsReport();
              })
          }

          if (this.gatewayStatusLooksLikePairing(this.statusText)) {
            Text($r('app.string.onboarding_run_on_gateway_host'))
              .fontSize(14)
              .fontColor('#4D5563')
            this.ReviewCommandBlock('openclaw devices list')
            this.ReviewCommandBlock('openclaw devices approve <requestId>')
            Text($r('app.string.onboarding_review_then_tap_connect_again'))
              .fontSize(14)
              .fontColor('#4D5563')
          }

          if (this.gatewayError.length > 0) {
            Text(this.gatewayError)
              .fontSize(14)
              .fontColor('#C8841A')
          }
        }
        .width('100%')
        .padding(14)
        .backgroundColor('rgba(200, 132, 26, 0.1)')
        .borderRadius(14)
        .border({ width: 1, color: 'rgba(200, 132, 26, 0.2)' })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
