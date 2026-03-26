/**
 * Chat session list screen.
 * Shows a compact list of sessions, and delegates selection to the parent.
 */
import { NodeRuntime } from '../NodeRuntime';
import type { ChatSessionEntry } from '../chat/ChatModels';
import type { ChatTabState } from './ChatTabScreen';
import { friendlyChipLabel, resolveSessionChoices } from '../chat/SessionChips';
import { HMRouterMgr } from '@hadss/hmrouter';

interface ChatNavRouteParams {
  sessionKey: string;
}

@Component
export struct ChatSessionListScreen {
  @Prop isConnected: boolean;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

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

  private attachChatListener(): void {
    const chat = this.nodeRuntime.getChatController();
    if (chat) {
      chat.setListener((state) => {
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
  }

  private sessionChoices(): ChatSessionEntry[] {
    return resolveSessionChoices(
      this.chatState.sessionKey,
      this.chatState.sessions,
      this.chatState.mainSessionKey,
    );
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text($r('app.string.chat_session_label'))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4D5563')
          .layoutWeight(1)
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
      } else {
        List({ space: 10 }) {
          ForEach(this.sessionChoices(), (entry: ChatSessionEntry) => {
            ListItem() {
              Button(friendlyChipLabel(entry))
                .width('100%')
                .fontSize(14)
                .fontWeight(entry.key === this.chatState.sessionKey ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(entry.key === this.chatState.sessionKey ? '#FFFFFF' : '#17181C')
                .backgroundColor(entry.key === this.chatState.sessionKey ? '#1D5DD8' : '#FFFFFF')
                .borderRadius(14)
                .border({ width: 1, color: entry.key === this.chatState.sessionKey ? '#184DAF' : '#E5E7EC' })
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .onClick(() => {
                  const c = this.nodeRuntime.getChatController();
                  c?.load(entry.key);
                  // Navigate to chat detail page via HMRouter push.
                  const params: ChatNavRouteParams = { sessionKey: entry.key };
                  HMRouterMgr.to('chat').withParam(params).push();
                })
            }
          }, (entry: ChatSessionEntry) => entry.key)
        }
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

