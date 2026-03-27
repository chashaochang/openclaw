/**
 * Chat session list screen.
 * Shows a compact list of sessions, and delegates selection to the parent.
 */
import { common } from '@kit.AbilityKit';
import { NodeRuntime } from '../NodeRuntime';
import type { ChatSessionEntry } from '../chat/ChatModels';
import type { ChatTabState } from './ChatTabScreen';
import { friendlyChipLabel, friendlySessionKeyLabel, resolveSessionChoices } from '../chat/SessionChips';
import { HMRouterMgr } from '@hadss/hmrouter';

interface ChatNavRouteParams {
  sessionKey: string;
}

@Component
export struct ChatSessionListScreen {
  @Prop isConnected: boolean;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  private chatListenerId: number = -1;

  @State chatState: ChatTabState = {
    messages: [],
    errorText: null,
    healthOk: false,
    streamingAssistantText: null,
    pendingRunCount: 0,
    sessionKey: 'main',
    mainSessionKey: 'main',
    thinkingLevel: 'off',
    sessions: [],
    pendingToolCalls: [],
  };

  aboutToAppear(): void {
    this.attachChatListener();
    const c = this.nodeRuntime.getChatController();
    if (c && (!this.chatState.sessions || this.chatState.sessions.length === 0)) {
      c.refreshSessions();
    }
  }

  aboutToDisappear(): void {
    const chat = this.nodeRuntime.getChatController();
    if (chat && this.chatListenerId >= 0) {
      chat.removeListener(this.chatListenerId);
      this.chatListenerId = -1;
    }
  }

  private attachChatListener(): void {
    const chat = this.nodeRuntime.getChatController();
    if (!chat || this.chatListenerId >= 0) {
      return;
    }
    this.chatListenerId = chat.addListener((state) => {
      // Keep only list-relevant fields.
      this.chatState = {
        messages: [],
        errorText: state.errorText,
        healthOk: state.healthOk,
        streamingAssistantText: null,
        pendingRunCount: 0,
        sessionKey: state.sessionKey,
        mainSessionKey: state.mainSessionKey,
        thinkingLevel: state.thinkingLevel,
        sessions: state.sessions,
        pendingToolCalls: [],
      };
    });
  }

  private sessionChoices(): ChatSessionEntry[] {
    return resolveSessionChoices(
      this.chatState.sessionKey,
      this.chatState.sessions,
      this.chatState.mainSessionKey,
    );
  }

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

  private isCurrentSession(entry: ChatSessionEntry): boolean {
    return entry.key === this.chatState.sessionKey;
  }

  private formatSessionUpdatedAt(updatedAtMs?: number): string {
    if (updatedAtMs === undefined || !Number.isFinite(updatedAtMs) || updatedAtMs <= 0) {
      return 'No recent activity';
    }
    const diffMs = Math.max(0, Date.now() - updatedAtMs);
    const minuteMs = 60 * 1000;
    const hourMs = 60 * minuteMs;
    const dayMs = 24 * hourMs;
    if (diffMs < minuteMs) {
      return 'Updated just now';
    }
    if (diffMs < hourMs) {
      return `Updated ${Math.max(1, Math.floor(diffMs / minuteMs))}m ago`;
    }
    if (diffMs < dayMs) {
      return `Updated ${Math.max(1, Math.floor(diffMs / hourMs))}h ago`;
    }
    if (diffMs < 2 * dayMs) {
      return 'Updated yesterday';
    }
    return `Updated ${Math.max(2, Math.floor(diffMs / dayMs))}d ago`;
  }

  private sessionMetaLine(entry: ChatSessionEntry): string {
    if ((entry.derivedTitle ?? '').trim().length > 0) {
      return (entry.derivedTitle ?? '').trim();
    }
    if (entry.displayName && entry.displayName.trim().length > 0) {
      return friendlySessionKeyLabel(entry.key);
    }
    return this.formatSessionUpdatedAt(entry.updatedAtMs);
  }

  private sessionPreviewLine(entry: ChatSessionEntry): string {
    const preview = (entry.lastMessagePreview ?? '').replace(/\s+/g, ' ').trim();
    if (preview.length > 0) {
      return preview;
    }
    return this.formatSessionUpdatedAt(entry.updatedAtMs);
  }

  @Builder
  SessionCard(entry: ChatSessionEntry) {
    Button() {
      Row({ space: 12 }) {
        if (this.isCurrentSession(entry)) {
          Column()
            .width(4)
            .height(48)
            .borderRadius(999)
            .backgroundColor('#1D5DD8')
        }

        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Column({ space: 3 }) {
              Text(friendlyChipLabel(entry))
                .fontSize(15)
                .fontWeight(this.isCurrentSession(entry) ? FontWeight.Bold : FontWeight.Medium)
                .fontColor('#17181C')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.sessionMetaLine(entry))
                .fontSize(11)
                .fontColor(this.isCurrentSession(entry) ? '#365D9D' : '#6B7280')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row() {
              Text(this.isCurrentSession(entry) ? 'Current' : 'Open')
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isCurrentSession(entry) ? '#8A5A00' : '#1D5DD8')
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.isCurrentSession(entry) ? '#FFE9A8' : '#ECF3FF')
            .border({ width: 1, color: this.isCurrentSession(entry) ? '#F3C64D' : '#CFE0FF' })
            .borderRadius(999)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.sessionPreviewLine(entry))
            .fontSize(11)
            .fontColor(this.isCurrentSession(entry) ? '#45668F' : '#8A92A2')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.isCurrentSession(entry) ? '#F4F8FF' : '#FFFFFF')
    .borderRadius(16)
    .border({ width: 1, color: this.isCurrentSession(entry) ? '#CFE0FF' : '#E5E7EC' })
    .onClick(() => {
      const c = this.nodeRuntime.getChatController();
      c?.load(entry.key);
      const params: ChatNavRouteParams = { sessionKey: entry.key };
      HMRouterMgr.to('chat').withParam(params).push();
    })
  }

  build() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Row() {
          Column({ space: 3 }) {
            Text($r('app.string.chat_session_label'))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#4D5563')
            Text(this.chatState.healthOk ? 'Pick up where you left off.' : 'Browse sessions while the gateway reconnects.')
              .fontSize(13)
              .fontColor('#6B7280')
          }
          .layoutWeight(1)

          Row() {
            Text(this.chatState.healthOk ? this.resStr($r('app.string.status_connected')) : this.resStr($r('app.string.status_offline')))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.chatState.healthOk ? '#2F8C5A' : '#C8841A')
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.chatState.healthOk ? '#E8F5E9' : '#FFF8E8')
          .borderRadius(999)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.chatState.errorText) {
          Text(this.chatState.errorText)
            .fontSize(12)
            .fontColor('#dc3545')
            .padding(8)
            .backgroundColor('#FFFFFF')
            .borderRadius(10)
            .border({ width: 1, color: '#dc3545' })
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .border({ width: 1, color: '#E5E7EC' })

      if (this.sessionChoices().length === 0) {
        Column({ space: 4 }) {
          Text($r('app.string.chat_sessions_empty'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17181C')
          if (!this.isConnected) {
            Text($r('app.string.chat_empty_state'))
              .fontSize(14)
              .fontColor('#4D5563')
          }
        }
        .padding(12)
      } else {
        List({ space: 10 }) {
          ForEach(this.sessionChoices(), (entry: ChatSessionEntry) => {
            ListItem() {
              this.SessionCard(entry)
            }
          }, (entry: ChatSessionEntry) => entry.key)
        }
        .layoutWeight(1)
        .divider({ strokeWidth: 0 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#F7F8FA')
  }
}
