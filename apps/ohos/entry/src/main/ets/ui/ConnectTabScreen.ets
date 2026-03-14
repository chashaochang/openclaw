/**
 * Connect tab: matches Android ConnectTabScreen structure.
 * Heading, active endpoint, gateway state, primary button, expandable advanced controls.
 */
import { common } from '@kit.AbilityKit';
import { NodeRuntime } from '../NodeRuntime';
import {
  decodeGatewaySetupCode,
  parseGatewayEndpoint,
  resolveScannedSetupCode,
  composeGatewayManualUrl,
} from '../common/GatewaySetupCode';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { promptAction } from '@kit.ArkUI';

@Component
export struct ConnectTabScreen {
  @Prop statusText: string;
  @Prop isConnected: boolean;
  @Prop remoteAddress: string;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

  @State inputMode: 'setupCode' | 'manual' = 'setupCode';
  @State setupCodeInput: string = '';
  @State hostInput: string = '10.0.2.2';
  @State portInput: string = '18789';
  @State useTls: boolean = false;
  @State tokenInput: string = '';
  @State passwordInput: string = '';
  @State connecting: boolean = false;
  @State scanning: boolean = false;
  @State validationText: string = '';
  @State advancedOpen: boolean = false;

  private setupResolvedEndpoint(): string {
    const decoded = decodeGatewaySetupCode(this.setupCodeInput.trim());
    if (!decoded) return '';
    const ep = parseGatewayEndpoint(decoded.url);
    return ep?.displayUrl ?? '';
  }

  private manualResolvedEndpoint(): string {
    const url = composeGatewayManualUrl(this.hostInput, this.portInput, this.useTls);
    if (!url) return '';
    const ep = parseGatewayEndpoint(url);
    return ep?.displayUrl ?? '';
  }

  private activeEndpoint(): string {
    if (this.isConnected && this.remoteAddress) return this.remoteAddress;
    if (this.inputMode === 'setupCode') return this.setupResolvedEndpoint();
    return this.manualResolvedEndpoint();
  }

  aboutToAppear(): void {
    this.nodeRuntime.getManualHost().then((h: string) => { this.hostInput = h || '10.0.2.2'; });
    this.nodeRuntime.getManualPort().then((p: string) => { this.portInput = p || '18789'; });
    this.nodeRuntime.getManualTls().then((t: boolean) => { this.useTls = t; });
    this.nodeRuntime.getGatewayToken().then((t: string) => { this.tokenInput = t; });
    this.nodeRuntime.getGatewayPassword().then((p: string) => { this.passwordInput = p; });
    this.nodeRuntime.getManualEnabled().then((enabled: boolean) => {
      if (enabled) {
        this.inputMode = 'manual';
      }
    });
  }

  private async doScan(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() ?? AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      this.validationText = 'Context unavailable';
      return;
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: false,
      enableAlbum: true,
    };
    this.scanning = true;
    this.validationText = '';
    try {
      const result = await scanBarcode.startScanForResult(ctx, options);
      const raw = result?.originalValue?.trim();
      const invalidMsg = 'Invalid setup code';
      if (!raw) {
        this.validationText = invalidMsg;
        return;
      }
      const setupCode = resolveScannedSetupCode(raw);
      if (!setupCode) {
        this.validationText = invalidMsg;
        return;
      }
      const decoded = decodeGatewaySetupCode(setupCode);
      if (!decoded) {
        this.validationText = invalidMsg;
        return;
      }
      const endpoint = parseGatewayEndpoint(decoded.url);
      if (!endpoint) {
        this.validationText = invalidMsg;
        return;
      }
      this.setupCodeInput = setupCode;
      this.hostInput = endpoint.host;
      this.portInput = String(endpoint.port);
      this.useTls = endpoint.tls;
      this.tokenInput = decoded.token ?? '';
      this.passwordInput = decoded.password ?? '';
      await this.nodeRuntime.saveManualConfig(
        endpoint.host,
        endpoint.port,
        endpoint.tls,
        decoded.token ?? '',
        decoded.password ?? ''
      );
    } catch (e) {
      this.validationText = e instanceof Error ? e.message : String(e);
      promptAction.showToast({ message: this.validationText });
    } finally {
      this.scanning = false;
    }
  }

  private async doConnect(): Promise<void> {
    this.connecting = true;
    this.validationText = '';
    try {
      const useSetupCode = this.inputMode === 'setupCode' && this.setupCodeInput.trim().length > 0;
      if (useSetupCode) {
        const decoded = decodeGatewaySetupCode(this.setupCodeInput.trim());
        if (!decoded) {
          this.validationText = 'Paste a valid setup code to connect.';
          return;
        }
        const endpoint = parseGatewayEndpoint(decoded.url);
        if (!endpoint) {
          this.validationText = 'Invalid gateway URL in setup code';
          return;
        }
        await this.nodeRuntime.saveManualConfig(
          endpoint.host,
          endpoint.port,
          endpoint.tls,
          decoded.token ?? '',
          decoded.password ?? ''
        );
        await this.nodeRuntime.connect(
          endpoint.host,
          endpoint.port,
          endpoint.tls,
          decoded.token ?? '',
          decoded.password ?? ''
        );
      } else {
        const host = this.hostInput.trim();
        const port = parseInt(this.portInput, 10) || 18789;
        if (host.length === 0) {
          this.validationText = 'Paste a valid setup code to connect.';
          return;
        }
        await this.nodeRuntime.saveManualConfig(
          host,
          port,
          this.useTls,
          this.tokenInput.trim(),
          this.passwordInput.trim()
        );
        await this.nodeRuntime.connect(
          host,
          port,
          this.useTls,
          this.tokenInput.trim(),
          this.passwordInput.trim()
        );
      }
    } catch (e) {
      this.validationText = e instanceof Error ? e.message : String(e);
    } finally {
      this.connecting = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 6 }) {
          Text($r('app.string.connect_heading_kicker'))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1D5DD8')
          Text($r('app.string.connect_heading_title'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
          Text($r('app.string.connect_heading_subtitle'))
            .fontSize(14)
            .fontColor('#4D5563')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Column({ space: 4 }) {
          Text($r('app.string.connect_active_endpoint'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4D5563')
          Text(this.activeEndpoint() || 'Not set')
            .fontSize(14)
            .fontFamily('monospace')
            .fontColor('#17181C')
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text($r('app.string.connect_gateway_state'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#4D5563')
          Text(this.statusText)
            .fontSize(14)
            .fontColor(this.isConnected ? '#2F8C5A' : '#17181C')
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })
        .alignItems(HorizontalAlign.Start)

        Button(this.isConnected ? $r('app.string.connect_primary_disconnect') : $r('app.string.connect_primary_connect'))
          .width('100%')
          .height(52)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(this.isConnected ? '#dc3545' : '#1D5DD8')
          .borderRadius(14)
          .enabled(!this.connecting)
          .onClick(() => {
            if (this.isConnected) {
              this.nodeRuntime.disconnect();
              this.validationText = '';
              return;
            }
            this.doConnect();
          })

        Column() {
          Row() {
            Column({ space: 2 }) {
              Text($r('app.string.connect_advanced_controls_title'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.connect_advanced_controls_subtitle'))
                .fontSize(12)
                .fontColor('#4D5563')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Blank()
            SymbolGlyph(this.advancedOpen ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(16)
              .fontColor(['#4D5563'])
              .fontWeight(FontWeight.Bold)
          }
          .width('100%')
          .padding(14)
          .onClick(() => {
            this.advancedOpen = !this.advancedOpen;
          })
        }
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(14)
        .border({ width: 1, color: '#E5E7EC' })

        if (this.advancedOpen) {
          Column({ space: 12 }) {
            Text($r('app.string.connect_connection_method'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#666666')
            Row({ space: 8 }) {
              Button($r('app.string.connect_method_setup_code'))
                .layoutWeight(1)
                .height(40)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .backgroundColor(this.inputMode === 'setupCode' ? '#1D5DD8' : '#F6F7FA')
                .fontColor(this.inputMode === 'setupCode' ? '#FFFFFF' : '#17181C')
                .borderRadius(12)
                .border({ width: 1, color: this.inputMode === 'setupCode' ? '#184DAF' : '#D6DAE2' })
                .onClick(() => {
                  this.inputMode = 'setupCode';
                  this.validationText = '';
                })
              Button($r('app.string.connect_method_manual'))
                .layoutWeight(1)
                .height(40)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .backgroundColor(this.inputMode === 'manual' ? '#1D5DD8' : '#F6F7FA')
                .fontColor(this.inputMode === 'manual' ? '#FFFFFF' : '#17181C')
                .borderRadius(12)
                .border({ width: 1, color: this.inputMode === 'manual' ? '#184DAF' : '#D6DAE2' })
                .onClick(() => {
                  this.inputMode = 'manual';
                  this.validationText = '';
                })
            }

            Text($r('app.string.connect_run_on_gateway_host'))
              .fontSize(14)
              .fontColor('#4D5563')
            Row() {
              Column()
                .width(3)
                .height(42)
                .backgroundColor('#3FC97A')
                .borderRadius(2)
              Text('openclaw qr --setup-code-only')
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
            Row() {
              Column()
                .width(3)
                .height(42)
                .backgroundColor('#3FC97A')
                .borderRadius(2)
              Text('openclaw qr --json')
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

            if (this.inputMode === 'setupCode') {
              Button($r('app.string.connect_scan_qr'))
                .enabled(!this.scanning && !this.connecting)
                .borderRadius(12)
                .onClick(() => {
                  if (canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
                    this.doScan();
                  } else {
                    this.validationText = 'Device does not support QR scanning';
                    promptAction.showToast({ message: this.validationText });
                  }
                })
              Text($r('app.string.connect_setup_code_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              TextInput({
                placeholder: $r('app.string.connect_setup_code_placeholder'),
                text: this.setupCodeInput
              })
                .onChange((v: string) => {
                  this.setupCodeInput = v;
                  this.validationText = '';
                })
                .height(80)
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: '#E5E7EC' })
              if (this.setupResolvedEndpoint()) {
                Column({ space: 4 }) {
                  Text($r('app.string.connect_resolved_endpoint'))
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#4D5563')
                  Text(this.setupResolvedEndpoint())
                    .fontSize(14)
                    .fontFamily('monospace')
                    .fontColor('#17181C')
                }
                .width('100%')
              }
            } else {
              Row({ space: 8 }) {
                Button($r('app.string.connect_quickfill_android_emulator'))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .backgroundColor('#ECF3FF')
                  .fontColor('#1D5DD8')
                  .borderRadius(999)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.hostInput = '10.0.2.2';
                    this.portInput = '18789';
                    this.useTls = false;
                    this.validationText = '';
                  })
                Button($r('app.string.connect_quickfill_localhost'))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .backgroundColor('#ECF3FF')
                  .fontColor('#1D5DD8')
                  .borderRadius(999)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.hostInput = '127.0.0.1';
                    this.portInput = '18789';
                    this.useTls = false;
                    this.validationText = '';
                  })
              }
              Text($r('app.string.connect_host_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              TextInput({ placeholder: '10.0.2.2', text: this.hostInput })
                .onChange((v: string) => {
                  this.hostInput = v;
                  this.validationText = '';
                })
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: '#E5E7EC' })
              Text($r('app.string.connect_port_label'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              TextInput({ placeholder: '18789', text: this.portInput })
                .type(InputType.Number)
                .onChange((v: string) => {
                  this.portInput = v;
                  this.validationText = '';
                })
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: '#E5E7EC' })
              Row() {
                Column({ space: 2 }) {
                  Text($r('app.string.connect_use_tls'))
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#17181C')
                  Text($r('app.string.connect_use_tls_subtitle'))
                    .fontSize(12)
                    .fontColor('#4D5563')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.useTls })
                  .onChange((v: boolean) => {
                    this.useTls = v;
                    this.validationText = '';
                  })
              }
              Text($r('app.string.connect_token_optional'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              TextInput({ placeholder: 'token', text: this.tokenInput })
                .onChange((v: string) => { this.tokenInput = v; })
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: '#E5E7EC' })
              Text($r('app.string.connect_password_optional'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              TextInput({ placeholder: 'password', text: this.passwordInput })
                .type(InputType.Password)
                .onChange((v: string) => { this.passwordInput = v; })
                .backgroundColor('#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: '#E5E7EC' })
              if (this.manualResolvedEndpoint()) {
                Column({ space: 4 }) {
                  Text($r('app.string.connect_resolved_endpoint'))
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#4D5563')
                  Text(this.manualResolvedEndpoint())
                    .fontSize(14)
                    .fontFamily('monospace')
                    .fontColor('#17181C')
                }
                .width('100%')
              }
            }

            Button($r('app.string.connect_run_onboarding_again'))
              .backgroundColor(Color.Transparent)
              .fontColor('#1D5DD8')
              .borderRadius(12)
              .onClick(async () => {
                await this.nodeRuntime.setOnboardingCompleted(false);
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .border({ width: 1, color: '#E5E7EC' })
          .alignItems(HorizontalAlign.Start)
        }

        if (this.validationText) {
          Text(this.validationText)
            .fontSize(12)
            .fontColor('#C8841A')
        }
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
  }
}
