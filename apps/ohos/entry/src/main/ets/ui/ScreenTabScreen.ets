/**
 * Screen tab: ArkWeb canvas (scaffold + A2UI) matching Android CanvasScreen behavior.
 */
import { webview } from '@kit.ArkWeb';
import { NodeRuntime } from '../NodeRuntime';

interface WebPageBeginPayload {
  url?: string;
}

@Component
export struct ScreenTabScreen {
  @Prop isConnected: boolean = false;
  @Prop statusText: string = '';
  @Prop visible: boolean = true;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  private webCtl: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.nodeRuntime.getCanvasWebHost().attach(this.webCtl);
    void this.nodeRuntime.refreshHomeCanvasOverviewIfConnected();
  }

  aboutToDisappear(): void {
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
          const url = event?.url;
          if (url !== undefined && url.length > 0) {
            this.nodeRuntime.getCanvasWebHost().setCurrentUrl(url);
          }
        })
        .onPageEnd(() => {
          this.nodeRuntime.getCanvasWebHost().notifyPageEnd();
        })
        .width('100%')
        .layoutWeight(1)

      if (this.isConnected && this.statusText.trim().length > 0) {
        Text(this.statusText.trim())
          .fontSize(11)
          .fontColor('#2F8C5A')
          .padding({ left: 12, right: 12, top: 6, bottom: 8 })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#05060a')
  }
}
