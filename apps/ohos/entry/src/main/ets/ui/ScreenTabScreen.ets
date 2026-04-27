/**
 * Screen tab: ArkWeb canvas (scaffold + A2UI) matching Android CanvasScreen behavior.
 */
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { NodeRuntime, type CanvasUiState } from '../NodeRuntime';

interface WebPageBeginPayload {
  url?: string;
}

type LooseValue = object | string | number | boolean | null | undefined;

function asRecord(value: LooseValue): Record<string, LooseValue> | null {
  if (typeof value !== 'object' || value === null) {
    return null;
  }
  return value as Record<string, LooseValue>;
}

function readPath(root: LooseValue, path: string[]): LooseValue {
  let current: LooseValue = root;
  for (let i = 0; i < path.length; i++) {
    const record = asRecord(current);
    if (!record) {
      return undefined;
    }
    current = record[path[i]];
  }
  return current;
}

function readStringPath(root: LooseValue, path: string[]): string | null {
  const value = readPath(root, path);
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function readNumberPath(root: LooseValue, path: string[]): number | null {
  const value = readPath(root, path);
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function readBooleanPath(root: LooseValue, path: string[]): boolean | null {
  const value = readPath(root, path);
  return typeof value === 'boolean' ? value : null;
}

function extractEventUrl(event: LooseValue): string | null {
  return readStringPath(event, ['url']) ?? readStringPath(event, ['request', 'url']);
}

function isMainFrameEvent(event: LooseValue): boolean {
  return readBooleanPath(event, ['request', 'isMainFrame']) ?? readBooleanPath(event, ['isMainFrame']) ?? true;
}

function defaultCanvasUiState(): CanvasUiState {
  return {
    a2uiHydrated: false,
    rehydratePending: false,
    rehydrateErrorText: null,
    pageLoading: false,
    pageErrorText: null,
    pageErrorDetail: null,
    targetUrl: null,
    currentUrl: null,
    isDefaultScaffold: true,
  };
}

@Component
export struct ScreenTabScreen {
  @Prop isConnected: boolean = false;
  @Prop visible: boolean = true;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State canvasState: CanvasUiState = defaultCanvasUiState();
  private webCtl: webview.WebviewController = new webview.WebviewController();
  private previousConnected = false;

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

  private maybeAutoRequestCanvasRehydrate(source: string): void {
    if (!this.visible || !this.isConnected) {
      return;
    }
    if (!this.canvasState.isDefaultScaffold) {
      return;
    }
    if (this.canvasState.a2uiHydrated || this.canvasState.rehydratePending) {
      return;
    }
    void this.nodeRuntime.requestCanvasRehydrate(source, false);
  }

  private hasPageIssue(): boolean {
    return (this.canvasState.pageErrorText?.trim().length ?? 0) > 0;
  }

  private formatCanvasUrl(url: string | null, isScaffold: boolean): string {
    const trimmed = url?.trim() ?? '';
    if (trimmed.length > 0) {
      return trimmed;
    }
    if (isScaffold) {
      return this.resStr($r('app.string.screen_tab_local_scaffold'));
    }
    return this.resStr($r('app.string.screen_tab_url_unknown'));
  }

  private overlayTitle(): string {
    if (!this.isConnected) {
      return this.resStr($r('app.string.screen_tab_offline_hint'));
    }
    const pageError = this.canvasState.pageErrorText?.trim() ?? '';
    if (pageError.length > 0) {
      return pageError;
    }
    if (this.canvasState.pageLoading) {
      return this.resStr($r('app.string.screen_tab_page_loading'));
    }
    if (this.canvasState.rehydratePending) {
      return this.resStr($r('app.string.screen_tab_rehydrate_pending'));
    }
    const err = this.canvasState.rehydrateErrorText?.trim() ?? '';
    if (err.length > 0) {
      return err;
    }
    if (!this.canvasState.a2uiHydrated && this.canvasState.isDefaultScaffold) {
      return this.resStr($r('app.string.screen_tab_rehydrate_ready'));
    }
    return '';
  }

  private overlayDetail(): string {
    if (!this.isConnected) {
      return '';
    }
    const pageDetail = this.canvasState.pageErrorDetail?.trim() ?? '';
    if (pageDetail.length > 0) {
      return pageDetail;
    }
    if (this.canvasState.pageLoading) {
      return `${this.resStr($r('app.string.screen_tab_target_label'))}: ` +
        `${this.formatCanvasUrl(this.canvasState.targetUrl, this.canvasState.isDefaultScaffold)}`;
    }
    if (this.canvasState.isDefaultScaffold && !this.canvasState.a2uiHydrated) {
      return this.resStr($r('app.string.screen_tab_restore_detail'));
    }
    return '';
  }

  private showOverlayCard(): boolean {
    if (!this.visible) {
      return false;
    }
    if (!this.isConnected) {
      return true;
    }
    if (this.canvasState.pageLoading || this.hasPageIssue()) {
      return true;
    }
    if (this.canvasState.rehydratePending) {
      return true;
    }
    const err = this.canvasState.rehydrateErrorText?.trim() ?? '';
    if (err.length > 0) {
      return true;
    }
    return !this.canvasState.a2uiHydrated && this.canvasState.isDefaultScaffold;
  }

  private showReloadButton(): boolean {
    return this.isConnected && this.hasPageIssue();
  }

  private showRestoreButton(): boolean {
    return this.isConnected && this.canvasState.isDefaultScaffold;
  }

  private handleReload(): void {
    this.nodeRuntime.reloadCanvasPage();
  }

  private handleRestore(): void {
    if (this.canvasState.rehydratePending || this.canvasState.pageLoading) {
      return;
    }
    void this.nodeRuntime.requestCanvasRehydrate('screen_tab_button', true);
  }

  private handleReceivedWebError(event: LooseValue): void {
    if (!isMainFrameEvent(event)) {
      return;
    }
    const url = extractEventUrl(event);
    const code = readNumberPath(event, ['error', 'errorCode']) ?? readNumberPath(event, ['errorCode']);
    const description = readStringPath(event, ['error', 'description']) ?? readStringPath(event, ['description']);
    const summary = code !== null
      ? `Canvas load failed (${code}).`
      : this.resStr($r('app.string.screen_tab_page_failed'));
    const detail = description !== null && url !== null ? `${description} ${url}` :
      description !== null ? description :
      url;
    this.nodeRuntime.onCanvasPageFailed(summary, detail, url);
  }

  private handleReceivedHttpError(event: LooseValue): void {
    if (!isMainFrameEvent(event)) {
      return;
    }
    const url = extractEventUrl(event);
    const statusCode = readNumberPath(event, ['response', 'statusCode']) ?? readNumberPath(event, ['statusCode']);
    const reason = readStringPath(event, ['response', 'reason']) ??
      readStringPath(event, ['response', 'reasonPhrase']) ??
      readStringPath(event, ['reason']) ??
      readStringPath(event, ['reasonPhrase']);
    const summary = statusCode !== null
      ? `Canvas page returned HTTP ${statusCode}.`
      : this.resStr($r('app.string.screen_tab_page_failed'));
    const detail = reason !== null && url !== null ? `${reason} ${url}` :
      reason !== null ? reason :
      url;
    this.nodeRuntime.onCanvasPageFailed(summary, detail, url);
  }

  private handleRenderExited(event: LooseValue): void {
    const didCrash = readBooleanPath(event, ['didCrash']);
    const priority = readNumberPath(event, ['rendererPriorityAtExit']);
    let detail = '';
    if (didCrash !== null) {
      detail = didCrash ? 'The canvas renderer crashed.' : 'The canvas renderer exited.';
    }
    if (priority !== null) {
      detail = detail.length > 0 ? `${detail} priority=${priority}` : `Renderer priority=${priority}`;
    }
    this.nodeRuntime.onCanvasPageFailed(
      this.resStr($r('app.string.screen_tab_renderer_exited')),
      detail.length > 0 ? detail : null,
      this.canvasState.currentUrl ?? this.canvasState.targetUrl,
    );
  }

  aboutToAppear(): void {
    this.nodeRuntime.getCanvasWebHost().attach(this.webCtl);
    this.nodeRuntime.setCanvasUiListener((state: CanvasUiState) => {
      this.canvasState = state;
    });
    void this.nodeRuntime.refreshHomeCanvasOverviewIfConnected();
    this.maybeAutoRequestCanvasRehydrate('screen_tab_appear');
  }

  aboutToUpdate(): void {
    if (this.isConnected && !this.previousConnected) {
      this.maybeAutoRequestCanvasRehydrate('screen_tab_connected');
    }
    this.previousConnected = this.isConnected;
  }

  aboutToDisappear(): void {
    this.nodeRuntime.setCanvasUiListener(null);
    this.nodeRuntime.getCanvasWebHost().detach(this.webCtl);
  }

  build() {
    Column() {
      Web({
        src: $rawfile('CanvasScaffold/scaffold.html'),
        controller: this.webCtl,
      })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onlineImageAccess(true)
        .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
        .javaScriptProxy({
          object: this.nodeRuntime.getCanvasA2UIBridge(),
          name: 'openclawCanvasA2UIAction',
          methodList: ['postMessage'],
          controller: this.webCtl,
        })
        .onPageBegin((event: WebPageBeginPayload) => {
          this.nodeRuntime.onCanvasPageStarted(event?.url);
        })
        .onPageEnd((event: WebPageBeginPayload) => {
          this.nodeRuntime.onCanvasPageFinished(event?.url);
          this.nodeRuntime.getCanvasWebHost().notifyPageEnd();
          this.maybeAutoRequestCanvasRehydrate('screen_tab_page_end');
        })
        .onErrorReceive((event) => {
          this.handleReceivedWebError(event);
        })
        .onHttpErrorReceive((event) => {
          this.handleReceivedHttpError(event);
        })
        .onRenderExited((event) => {
          this.handleRenderExited(event);
        })
        .width('100%')
        .layoutWeight(1)

      if (this.showOverlayCard()) {
        Column({ space: 10 }) {
          Text(this.overlayTitle())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isConnected ? '#17181C' : '#8A92A2')
            .textAlign(TextAlign.Center)
            .width('100%')
          if (this.overlayDetail().length > 0) {
            Text(this.overlayDetail())
              .fontSize(12)
              .fontColor('#5C6474')
              .textAlign(TextAlign.Center)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          if (this.isConnected) {
            Column({ space: 6 }) {
              Text(`${this.resStr($r('app.string.screen_tab_target_label'))}: ` +
                `${this.formatCanvasUrl(this.canvasState.targetUrl, this.canvasState.isDefaultScaffold)}`)
                .fontSize(11)
                .fontColor('#5C6474')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${this.resStr($r('app.string.screen_tab_current_label'))}: ` +
                `${this.formatCanvasUrl(this.canvasState.currentUrl, this.canvasState.isDefaultScaffold)}`)
                .fontSize(11)
                .fontColor('#5C6474')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .width('100%')
          }
          if (this.isConnected && (this.showReloadButton() || this.showRestoreButton())) {
            Row({ space: 10 }) {
              if (this.showReloadButton()) {
                Button(this.resStr($r('app.string.screen_tab_reload_canvas')))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .height(36)
                  .layoutWeight(this.showRestoreButton() ? 1 : 0)
                  .backgroundColor('#FFFFFF')
                  .fontColor('#1D5DD8')
                  .borderRadius(12)
                  .border({ width: 1, color: '#C8D3E9' })
                  .onClick(() => {
                    this.handleReload();
                  })
              }
              if (this.showRestoreButton()) {
                Button(this.canvasState.rehydratePending ?
                  this.resStr($r('app.string.screen_tab_rehydrate_pending_button')) :
                  this.resStr($r('app.string.screen_tab_rehydrate_retry')))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(this.canvasState.rehydratePending || this.canvasState.pageLoading ? '#D6DAE2' : '#1D5DD8')
                  .fontColor('#FFFFFF')
                  .borderRadius(12)
                  .enabled(!this.canvasState.rehydratePending && !this.canvasState.pageLoading)
                  .onClick(() => {
                    this.handleRestore();
                  })
              }
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor('rgba(255, 255, 255, 0.94)')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#05060a')
    .visibility(this.visible ? Visibility.Visible : Visibility.Hidden)
  }
}
