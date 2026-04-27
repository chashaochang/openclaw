/**
 * Connect tab: matches Android ConnectTabScreen structure.
 * Heading, active endpoint, gateway state, primary button, expandable advanced controls.
 */
import { common } from '@kit.AbilityKit';
import { NodeRuntime } from '../NodeRuntime';
import type { GatewayTrustPrompt } from '../NodeRuntime';
import {
  decodeGatewaySetupCode,
  parseGatewayEndpoint,
  resolveScannedSetupCode,
  composeGatewayManualUrl,
} from '../common/GatewaySetupCode';
import { GatewayDiscovery, type GatewayEndpointInfo } from '../gateway/GatewayDiscovery';
import { normalizeFingerprintForDisplay } from '../gateway/GatewayTls';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { promptAction } from '@kit.ArkUI';
import {
  buildGatewayDiagnosticsReport,
  copyGatewayDiagnosticsReport,
  gatewayStatusForDisplay,
  gatewayStatusHasDiagnostics,
  gatewayStatusLooksLikePairing,
} from './GatewayDiagnostics';

@Component
export struct ConnectTabScreen {
  @Prop statusText: string;
  @Prop isConnected: boolean;
  @Prop remoteAddress: string;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

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
  @State discoveredGateways: GatewayEndpointInfo[] = [];
  @State discoveryStatusText: string = 'Searching for gateways…';
  @State selectedStableId: string = '';
  @State pendingTrust: GatewayTrustPrompt | null = null;
  private gatewayDiscovery: GatewayDiscovery | null = null;

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

  private diagnosticsReport(): string {
    return buildGatewayDiagnosticsReport(
      'connect tab',
      this.nodeRuntime.getVersion(),
      this.nodeRuntime.getDeviceModel(),
      this.activeEndpoint(),
      gatewayStatusForDisplay(this.statusText),
    );
  }

  private async copyDiagnostics(): Promise<void> {
    try {
      await copyGatewayDiagnosticsReport(
        this.diagnosticsReport(),
        this.resStr($r('app.string.connect_copy_report_toast')) || 'Copied gateway diagnostics',
      );
    } catch {
      await promptAction.showToast({
        message: this.resStr($r('app.string.connect_copy_report_failed')) || 'Copy failed',
      });
    }
  }

  aboutToAppear(): void {
    this.pendingTrust = this.nodeRuntime.getPendingGatewayTrustPrompt();
    this.nodeRuntime.setGatewayTrustListener((prompt) => {
      this.pendingTrust = prompt;
    });
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
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (ctx) {
      if (this.gatewayDiscovery === null) {
        this.gatewayDiscovery = new GatewayDiscovery(ctx);
      }
      this.gatewayDiscovery.start((endpoints, statusText) => {
        this.discoveredGateways = endpoints;
        this.discoveryStatusText = statusText;
      });
    } else {
      this.discoveryStatusText = 'Gateway discovery unavailable';
    }
  }

  aboutToDisappear(): void {
    this.nodeRuntime.setGatewayTrustListener(null);
    this.gatewayDiscovery?.stop();
  }

  private discoveredEndpointLabel(entry: GatewayEndpointInfo): string {
    return `${entry.host}:${entry.port} · ${entry.useTls ? 'TLS' : 'TCP'}`;
  }

  private applyDiscoveredEndpoint(entry: GatewayEndpointInfo): void {
    this.inputMode = 'manual';
    this.hostInput = entry.host;
    this.portInput = String(entry.port);
    this.useTls = entry.useTls;
    this.selectedStableId = entry.stableId;
    this.validationText = '';
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
      const invalidMsg = this.resStr($r('app.string.connect_qr_error_invalid')) || 'Invalid setup code';
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
      this.selectedStableId = '';
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
      if (this.inputMode === 'setupCode' && this.setupCodeInput.trim().length === 0) {
        this.validationText = this.resStr($r('app.string.connect_validation_setup_code')) || 'Paste a valid setup code to connect.';
        return;
      }
      const useSetupCode = this.inputMode === 'setupCode' && this.setupCodeInput.trim().length > 0;
      if (useSetupCode) {
        const decoded = decodeGatewaySetupCode(this.setupCodeInput.trim());
        if (!decoded) {
          this.validationText = this.resStr($r('app.string.connect_validation_setup_code')) || 'Paste a valid setup code to connect.';
          return;
        }
        const endpoint = parseGatewayEndpoint(decoded.url);
        if (!endpoint) {
          this.validationText = this.resStr($r('app.string.connect_invalid_gateway_url_in_setup')) || 'Invalid gateway URL in setup code';
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
          decoded.password ?? '',
          null
        );
      } else {
        const host = this.hostInput.trim();
        const port = parseInt(this.portInput, 10) || 18789;
        if (host.length === 0) {
          this.validationText = this.resStr($r('app.string.connect_validation_manual_host_port')) || 'Enter a valid manual host and port to connect.';
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
          this.passwordInput.trim(),
          this.selectedStableId.trim().length > 0 ? this.selectedStableId.trim() : null
        );
      }
    } catch (e) {
      this.validationText = e instanceof Error ? e.message : String(e);
    } finally {
      this.connecting = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
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
            Text(this.isConnected ? $r('app.string.connect_heading_subtitle_connected') : $r('app.string.connect_heading_subtitle_disconnected'))
              .fontSize(14)
              .fontColor('#4D5563')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Column({ space: 8 }) {
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.connect_discovery_title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#17181C')
                Text($r('app.string.connect_discovery_subtitle'))
                  .fontSize(12)
                  .fontColor('#4D5563')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(this.discoveryStatusText)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1D5DD8')
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            if (this.discoveredGateways.length === 0) {
              Text($r('app.string.connect_discovery_empty'))
                .fontSize(13)
                .fontColor('#8A92A2')
            } else {
              ForEach(this.discoveredGateways, (entry: GatewayEndpointInfo) => {
                Row({ space: 12 }) {
                  Column({ space: 2 }) {
                    Text(entry.name)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#17181C')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.discoveredEndpointLabel(entry))
                      .fontSize(12)
                      .fontColor('#8A92A2')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Button($r('app.string.connect_discovery_use'))
                    .height(34)
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .backgroundColor('#1D5DD8')
                    .fontColor(Color.White)
                    .borderRadius(12)
                    .onClick(() => {
                      this.applyDiscoveredEndpoint(entry);
                    })
                }
                .width('100%')
                .padding({ top: 6, bottom: 6 })
              }, (entry: GatewayEndpointInfo) => entry.stableId)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .border({ width: 1, color: '#E5E7EC' })
          .alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            Text($r('app.string.connect_active_endpoint'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#4D5563')
            Text(this.activeEndpoint() || this.resStr($r('app.string.connect_not_set')) || 'Not set')
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
              if (this.statusText.toLowerCase().includes('operator offline')) {
                this.validationText = '';
                this.connecting = true;
                this.nodeRuntime.refreshGatewayConnection().finally(() => {
                  this.connecting = false;
                });
                return;
              }
              this.doConnect();
            })

          if (!this.isConnected && gatewayStatusHasDiagnostics(this.statusText)) {
            Column({ space: 10 }) {
              Text($r('app.string.connect_last_gateway_error'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#C8841A')
              Text(gatewayStatusForDisplay(this.statusText))
                .fontSize(14)
                .fontFamily('monospace')
                .fontColor('#17181C')
              Text(this.resStr($r('app.string.connect_harmonyos_version_fmt')).replace('%1$s', this.nodeRuntime.getVersion()) || `OpenClaw HarmonyOS ${this.nodeRuntime.getVersion()}`)
                .fontSize(12)
                .fontColor('#4D5563')
              Button($r('app.string.connect_copy_report_button'))
                .width('100%')
                .height(46)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#FFFFFF')
                .fontColor('#C8841A')
                .borderRadius(12)
                .border({ width: 1, color: 'rgba(200, 132, 26, 0.3)' })
                .onClick(() => {
                  void this.copyDiagnostics();
                })
              if (gatewayStatusLooksLikePairing(this.statusText)) {
                Text($r('app.string.connect_pairing_hint'))
                  .fontSize(12)
                  .fontColor('#4D5563')
                Text('openclaw devices list')
                  .fontSize(13)
                  .fontFamily('monospace')
                  .fontColor('#E8EAEE')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .width('100%')
                  .backgroundColor('#15171B')
                  .borderRadius(12)
                  .border({ width: 1, color: '#2B2E35' })
                Text('openclaw devices approve <requestId>')
                  .fontSize(13)
                  .fontFamily('monospace')
                  .fontColor('#E8EAEE')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .width('100%')
                  .backgroundColor('#15171B')
                  .borderRadius(12)
                  .border({ width: 1, color: '#2B2E35' })
              }
            }
            .width('100%')
            .padding(14)
            .backgroundColor('rgba(200, 132, 26, 0.1)')
            .borderRadius(14)
            .border({ width: 1, color: 'rgba(200, 132, 26, 0.2)' })
            .alignItems(HorizontalAlign.Start)
          }

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
                    this.selectedStableId = '';
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
                    this.selectedStableId = '';
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
                      this.selectedStableId = '';
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
                      this.selectedStableId = '';
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
                    this.selectedStableId = '';
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
                    this.selectedStableId = '';
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
                      this.selectedStableId = '';
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
}
