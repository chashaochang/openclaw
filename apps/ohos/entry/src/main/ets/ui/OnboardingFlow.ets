/**
 * Onboarding flow: Welcome → Gateway → Permissions → FinalCheck.
 * Matches Android flow: scan QR primary, advanced setup with SetupCode/Manual.
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { promptAction } from '@kit.ArkUI';
import {
  decodeGatewaySetupCode,
  parseGatewayEndpoint,
  resolveScannedSetupCode,
  composeGatewayManualUrl,
} from '../common/GatewaySetupCode';
import type { GatewayEndpointConfig } from '../common/GatewaySetupCode';
import { NodeRuntime } from '../NodeRuntime';

type OnboardingStep = 'welcome' | 'gateway' | 'permissions' | 'finalCheck';
type GatewayInputMode = 'setupCode' | 'manual';

@Component
export struct OnboardingFlow {
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime =
    AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

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
  @State statusText: string = 'Offline';
  @State isConnected: boolean = false;
  @State enableCamera: boolean = false;
  @State enableMicrophone: boolean = false;
  @State enableNotifications: boolean = false;

  aboutToAppear(): void {
    this.nodeRuntime.setStatusListener((s) => {
      // Defer to next tick to avoid stack overflow when notifyStatus is called
      // synchronously during connect (e.g. from WebSocket callbacks).
      setTimeout(() => {
        this.statusText = s.statusText;
        this.isConnected = s.isConnected;
      }, 0);
    });
    this.statusText = this.nodeRuntime.getStatusText();
    this.isConnected = this.nodeRuntime.getIsConnected();
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
        this.gatewayError = 'Invalid setup code';
        return;
      }
      this.setupCode = code;
      this.gatewayInputMode = 'setupCode';
    } catch (_) {
      this.gatewayError = 'Scan failed';
    }
  }

  private goNext(): void {
    if (this.step === 'welcome') {
      this.step = 'gateway';
      return;
    }
    if (this.step === 'gateway') {
      if (this.gatewayInputMode === 'setupCode') {
        const decoded = decodeGatewaySetupCode(this.setupCode);
        if (!decoded) {
          this.gatewayError = 'Scan QR first or use Advanced setup';
          return;
        }
        const ep = parseGatewayEndpoint(decoded.url);
        if (!ep) {
          this.gatewayError = 'Setup code has invalid gateway URL';
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
          this.gatewayError = 'Manual endpoint is invalid';
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
      this.gatewayError = 'Invalid gateway URL';
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
    await this.nodeRuntime.setOnboardingCompleted(true);
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

  private localizeStatusText(raw: string): string {
    const s = raw.trim();
    if (s.length === 0) return 'Offline';
    return s;
  }

  private stepIndex(): number {
    return this.step === 'welcome' ? 1 : this.step === 'gateway' ? 2 : this.step === 'permissions' ? 3 : 4;
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
        Text(`Step ${this.stepIndex()} of 4`)
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
            .onClick(() => this.goNext())
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
  }

  @Builder
  WelcomeStep() {
    Column({ space: 12 }) {
      Text($r('app.string.onboarding_step_welcome_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17181C')
      Row({ space: 10 }) {
        Text('•')
          .fontSize(15)
          .fontColor('#1D5DD8')
        Text($r('app.string.onboarding_step_welcome_bullet_control_gateway'))
          .fontSize(15)
          .fontColor('#4D5563')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 10 }) {
        Text('•')
          .fontSize(15)
          .fontColor('#1D5DD8')
        Text($r('app.string.onboarding_step_welcome_bullet_connect_setup_code'))
          .fontSize(15)
          .fontColor('#4D5563')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 10 }) {
        Text('•')
          .fontSize(15)
          .fontColor('#1D5DD8')
        Text($r('app.string.onboarding_step_welcome_bullet_enable_permissions'))
          .fontSize(15)
          .fontColor('#4D5563')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Row({ space: 10 }) {
        Text('•')
          .fontSize(15)
          .fontColor('#1D5DD8')
        Text($r('app.string.onboarding_step_welcome_bullet_finish_check'))
          .fontSize(15)
          .fontColor('#4D5563')
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
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
        Text($r('app.string.onboarding_gateway_scan_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#17181C')
        Text($r('app.string.onboarding_run_on_gateway_host'))
          .fontSize(14)
          .fontColor('#4D5563')
        Text('openclaw qr')
          .fontSize(14)
          .fontFamily('monospace')
          .fontColor('#E8EAEE')
          .backgroundColor('#15171B')
          .padding(12)
          .borderRadius(12)
        Text($r('app.string.onboarding_then_scan_with_device'))
          .fontSize(14)
          .fontColor('#4D5563')
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

      Row() {
        Text($r('app.string.onboarding_perm_camera_title'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.enableCamera })
          .onChange((v) => { this.enableCamera = v; })
      }
      .width('100%')
      Divider().color('#E5E7EC')
      Row() {
        Text($r('app.string.onboarding_perm_microphone_title'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.enableMicrophone })
          .onChange((v) => { this.enableMicrophone = v; })
      }
      .width('100%')
      Divider().color('#E5E7EC')
      Row() {
        Text($r('app.string.onboarding_perm_notifications_title'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.enableNotifications })
          .onChange((v) => { this.enableNotifications = v; })
      }
      .width('100%')

      Text($r('app.string.onboarding_permissions_footer'))
        .fontSize(14)
        .fontColor('#4D5563')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FinalStep() {
    Column({ space: 12 }) {
      Text($r('app.string.onboarding_review_title'))
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17181C')

      Text($r('app.string.onboarding_review_method_label'))
        .fontSize(12)
        .fontColor('#4D5563')
      Text(this.gatewayInputMode === 'setupCode' ?
        $r('app.string.onboarding_review_method_qr_setup_code') :
        $r('app.string.connect_method_manual'))
        .fontSize(16)
        .fontColor('#17181C')

      Text($r('app.string.onboarding_review_gateway_label'))
        .fontSize(12)
        .fontColor('#4D5563')
      Text(this.gatewayEndpoint?.displayUrl ?? '')
        .fontSize(16)
        .fontColor('#17181C')

      Text($r('app.string.onboarding_review_enabled_perms_label'))
        .fontSize(12)
        .fontColor('#4D5563')
      Text(
        [this.enableCamera && 'Camera', this.enableMicrophone && 'Microphone', this.enableNotifications && 'Notifications']
          .filter(Boolean)
          .join(', ') || 'None selected'
      )
        .fontSize(16)
        .fontColor('#17181C')

      Text($r('app.string.onboarding_review_status_label'))
        .fontSize(12)
        .fontColor('#4D5563')
      Text(this.localizeStatusText(this.statusText))
        .fontSize(16)
        .fontColor(this.isConnected ? '#2F8C5A' : '#4D5563')
      Divider().color('#E5E7EC')

      if (!this.attemptedConnect) {
        Text($r('app.string.onboarding_review_connect_hint'))
          .fontSize(14)
          .fontColor('#4D5563')
      } else {
        if (this.isConnected) {
          Text($r('app.string.onboarding_review_connected_to_fmt'))
            .fontSize(14)
            .fontColor('#2F8C5A')
        } else {
          Column({ space: 8 }) {
            Text($r('app.string.onboarding_review_pairing_required_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#17181C')
            Text($r('app.string.onboarding_run_on_gateway_host'))
              .fontSize(14)
              .fontColor('#4D5563')
            Text('openclaw devices list')
              .fontSize(14)
              .fontFamily('monospace')
              .fontColor('#E8EAEE')
              .backgroundColor('#15171B')
              .padding(12)
              .borderRadius(12)
            Text('openclaw devices approve <requestId>')
              .fontSize(14)
              .fontFamily('monospace')
              .fontColor('#E8EAEE')
              .backgroundColor('#15171B')
              .padding(12)
              .borderRadius(12)
            Text($r('app.string.onboarding_review_then_tap_connect_again'))
              .fontSize(14)
              .fontColor('#4D5563')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 8 })
          if (this.gatewayError.length > 0) {
            Text(this.gatewayError)
              .fontSize(14)
              .fontColor('#C8841A')
              .margin({ top: 8 })
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
