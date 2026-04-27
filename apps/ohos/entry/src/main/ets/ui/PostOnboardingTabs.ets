/**
 * Tab container: Connect, Chat, Screen, Settings.
 * Voice entry now lives inside chat detail instead of the bottom tab bar.
 */
import { NodeRuntime } from '../NodeRuntime';
import { ConnectTabScreen } from './ConnectTabScreen';
import { ChatSessionListScreen } from './ChatSessionListScreen';
import { ScreenTabScreen } from './ScreenTabScreen';
import { SettingsTabScreen } from './SettingsTabScreen';
import { CameraHudOverlay } from './CameraHudOverlay';
import { CameraFlashOverlay } from './CameraFlashOverlay';
import { HMRouter } from '@hadss/hmrouter';
import type { CameraHudState } from '../NodeRuntime';

interface StatusChipColors {
  bg: string;
  dot: string;
  text: string;
}

@HMRouter({
  pageUrl: 'PostOnboardingTabs',
})
@Component
export struct PostOnboardingTabs {
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State activeTab: number = 0;
  @State screenTabStarted: boolean = false;
  @State statusText: string = 'Offline';
  @State isConnected: boolean = false;
  @State remoteAddress: string = '';
  @State cameraHud: CameraHudState | null = null;
  @State cameraFlashToken: number = 0;

  aboutToAppear(): void {
    this.nodeRuntime.setStatusListener((s) => {
      setTimeout(() => {
        this.statusText = s.statusText;
        this.isConnected = s.isConnected;
        this.remoteAddress = s.remoteAddress;
      }, 0);
    });
    this.nodeRuntime.setCameraHudListener((hud) => {
      setTimeout(() => {
        this.cameraHud = hud ? {
          token: hud.token,
          kind: hud.kind,
          message: hud.message,
        } : null;
      }, 0);
    });
    this.nodeRuntime.setCameraFlashListener((token) => {
      setTimeout(() => {
        this.cameraFlashToken = token;
      }, 0);
    });
    this.statusText = this.nodeRuntime.getStatusText();
    this.isConnected = this.nodeRuntime.getIsConnected();
    this.remoteAddress = this.nodeRuntime.getRemoteAddress();
    if (this.activeTab === 2) {
      this.screenTabStarted = true;
    }
  }

  private statusChipColor(): StatusChipColors {
    const lower = this.statusText.toLowerCase();
    if (this.isConnected) {
      const c: StatusChipColors = { bg: '#E8F5E9', dot: '#2F8C5A', text: '#2F8C5A' };
      return c;
    }
    if (lower.includes('connecting') || lower.includes('reconnecting')) {
      const c: StatusChipColors = { bg: '#ECF3FF', dot: '#1D5DD8', text: '#1D5DD8' };
      return c;
    }
    if (lower.includes('pairing') || lower.includes('approval') || lower.includes('auth')) {
      const c: StatusChipColors = { bg: '#FFF8E8', dot: '#C8841A', text: '#C8841A' };
      return c;
    }
    if (lower.includes('error') || lower.includes('failed')) {
      const c: StatusChipColors = { bg: '#FFEBEE', dot: '#dc3545', text: '#dc3545' };
      return c;
    }
    const c: StatusChipColors = { bg: '#F6F7FA', dot: '#8A92A2', text: '#4D5563' };
    return c;
  }

  @Builder
  TabItem(label: ResourceStr, iconRes: Resource, index: number) {
    Column({ space: 4 }) {
      SymbolGlyph(iconRes)
        .fontSize(22)
        .fontColor([this.activeTab === index ? '#1D5DD8' : '#8A92A2'])
      Text(label)
        .fontSize(11)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeTab === index ? '#1D5DD8' : '#4D5563')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.activeTab === index ? '#ECF3FF' : '#00000000')
    .borderRadius(16)
    .border(this.activeTab === index ? { width: 1, color: '#D5E2FA' } : { width: 0, color: '#00000000' })
    .onClick(() => {
      this.activeTab = index;
      if (index === 2) {
        this.screenTabStarted = true;
        void this.nodeRuntime.refreshHomeCanvasOverviewIfConnected();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      CameraFlashOverlay({ token: this.cameraFlashToken })
      Column() {
        Row() {
          Text($r('app.string.product_name_openclaw'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#17181C')
          Blank()
          Row({space:4}) {
            Row()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.statusChipColor().dot)
            Text(this.statusText)
              .fontSize(12)
              .fontColor(this.statusChipColor().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.statusChipColor().bg)
          .borderRadius(999)
          .border({ width: 1, color: '#E5E7EC' })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.SpaceBetween)

        Stack() {
          if (this.screenTabStarted) {
            ScreenTabScreen({
              isConnected: this.isConnected,
              visible: this.activeTab === 2,
            })
          }
          if (this.activeTab === 0) {
            ConnectTabScreen({
              statusText: this.statusText,
              isConnected: this.isConnected,
              remoteAddress: this.remoteAddress,
            })
          }
          if (this.activeTab === 1) {
            ChatSessionListScreen({
              isConnected: this.isConnected,
            })
          }
          if (this.activeTab === 2 && !this.screenTabStarted) {
            ScreenTabScreen({
              isConnected: this.isConnected,
              visible: true,
            })
          }
          if (this.activeTab === 3) {
            SettingsTabScreen()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)

        Row({ space: 6 }) {
          this.TabItem($r('app.string.tab_connect'), $r('sys.symbol.checkmark_circle_fill'), 0)
          this.TabItem($r('app.string.tab_chat'), $r('sys.symbol.message_on_message_fill'), 1)
          this.TabItem($r('app.string.tab_screen'), $r('sys.symbol.screen_share_fill'), 2)
          this.TabItem($r('app.string.tab_settings'), $r('sys.symbol.gearshape_fill'), 3)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .backgroundColor('#FFFFFF')
        .borderRadius({ topLeft: 24, topRight: 24 })
        .border({ width: 1, color: '#E5E7EC' })
        .shadow({ radius: 12, color: '#1A000000', offsetX: 0, offsetY: -2 })
      }
      CameraHudOverlay({ hud: this.cameraHud })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F8FA')
  }
}
