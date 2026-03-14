/**
 * Chat tab: matches Android ChatSheetContent structure and styling.
 * Session/connection row, error rail, message list with bubbles, composer.
 */
import { Markdown } from '@luvi/lv-markdown-in';
import { NodeRuntime } from '../NodeRuntime';
import type { ChatMessage, ChatMessageContent, ChatSessionEntry } from '../chat/ChatModels';

export interface ChatTabState {
  messages: ChatMessage[];
  errorText: string | null;
  healthOk: boolean;
  streamingAssistantText: string | null;
  pendingRunCount: number;
  sessionKey: string;
  thinkingLevel: string;
  sessions: ChatSessionEntry[];
}

interface ThinkingOption {
  value: string;
  labelKey: string;
}

function buildThinkingOptions(): ThinkingOption[] {
  const opts: ThinkingOption[] = [];
  opts.push({ value: 'off', labelKey: 'app.string.chat_thinking_off' });
  opts.push({ value: 'low', labelKey: 'app.string.chat_thinking_low' });
  opts.push({ value: 'medium', labelKey: 'app.string.chat_thinking_medium' });
  opts.push({ value: 'high', labelKey: 'app.string.chat_thinking_high' });
  return opts;
}

const THINKING_OPTIONS: ThinkingOption[] = buildThinkingOptions();

function defaultChatTabState(): ChatTabState {
  const s: ChatTabState = {
    messages: [],
    errorText: null,
    healthOk: false,
    streamingAssistantText: null,
    pendingRunCount: 0,
    sessionKey: 'main',
    thinkingLevel: 'off',
    sessions: [],
  };
  return s;
}

function friendlySessionName(entry: ChatSessionEntry): string {
  const name = entry.displayName?.trim();
  if (name && name.length > 0) return name;
  const key = (entry.key ?? '').trim();
  if (key === 'main') return 'Main';
  return key || 'Session';
}

function roleLabel(role: string): string {
  const r = role.trim().toLowerCase();
  if (r === 'user') return 'USER';
  if (r === 'system') return 'SYSTEM';
  return 'ASSISTANT';
}

@Component
export struct ChatTabScreen {
  @Prop isConnected: boolean;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State chatState: ChatTabState = defaultChatTabState();
  @State inputText: string = '';
  private listScroller: ListScroller = new ListScroller();
  private prevScrollKey: string = '';

  aboutToUpdate(): void {
    const s = this.chatState;
    const streamLen = s.streamingAssistantText?.length ?? 0;
    const key = `${s.messages.length}-${s.pendingRunCount}-${streamLen}`;
    if (key !== this.prevScrollKey) {
      this.prevScrollKey = key;
      const lastIdx = this.getListLastIndex();
      const total = (s.streamingAssistantText ? 1 : 0) + (s.pendingRunCount > 0 && !s.streamingAssistantText ? 1 : 0) + s.messages.length;
      if (total > 0 && lastIdx >= 0 && lastIdx < total) {
        setTimeout(() => {
          this.listScroller.scrollToIndex(lastIdx, true, ScrollAlign.END);
        }, 150);
      }
    }
  }

  private getListLastIndex(): number {
    const s = this.chatState;
    const empty = (!s.healthOk && s.messages.length === 0) ||
      (s.healthOk && s.messages.length === 0 && !s.streamingAssistantText && s.pendingRunCount === 0);
    if (empty) return 0;
    const extra = (s.streamingAssistantText ? 1 : 0) + (s.pendingRunCount > 0 && !s.streamingAssistantText ? 1 : 0);
    const total = extra + s.messages.length;
    return total > 0 ? total - 1 : 0;
  }

  aboutToAppear(): void {
    this.attachChatListener();
  }

  private attachChatListener(): void {
    const chat = this.nodeRuntime.getChatController();
    if (chat) {
      chat.setListener((state) => {
        const next: ChatTabState = {
          messages: state.messages,
          errorText: state.errorText,
          healthOk: state.healthOk,
          streamingAssistantText: state.streamingAssistantText,
          pendingRunCount: state.pendingRunCount,
          sessionKey: state.sessionKey,
          thinkingLevel: state.thinkingLevel,
          sessions: state.sessions,
        };
        setTimeout(() => {
          this.chatState = next;
        }, 0);
      });
    }
  }

  @Builder
  MessageBubble(msg: ChatMessage, isUser: boolean) {
    Row() {
      Column({ space: 3 }) {
        Text(roleLabel(msg.role))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(isUser ? '#1D5DD8' : '#4D5563')
        Markdown({ text: this.getTextContent(msg.content) || ' ', mode: 'text' })
      }
      .width('90%')
      .padding({ left: 11, right: 11, top: 8, bottom: 8 })
      .backgroundColor(isUser ? '#ECF3FF' : '#FFFFFF')
      .borderRadius(12)
      .border({ width: 1, color: isUser ? '#1D5DD8' : '#D6DAE2' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(isUser ? FlexAlign.End : FlexAlign.Start)
  }

  private getTextContent(content: ChatMessageContent[]): string {
    const part = content.find((c) => c.type === 'text');
    return part?.text ?? '';
  }

  @Builder
  SessionChip(entry: ChatSessionEntry) {
    Button(friendlySessionName(entry))
      .fontSize(12)
      .fontWeight(entry.key === this.chatState.sessionKey ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(entry.key === this.chatState.sessionKey ? '#1D5DD8' : '#FFFFFF')
      .fontColor(entry.key === this.chatState.sessionKey ? '#FFFFFF' : '#17181C')
      .borderRadius(14)
      .border({
        width: 1,
        color: entry.key === this.chatState.sessionKey ? '#184DAF' : '#D6DAE2'
      })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.nodeRuntime.getChatController()?.load(entry.key);
      })
  }

  @Builder
  ThinkingChip(opt: ThinkingOption) {
    Button($r(opt.labelKey))
      .fontSize(12)
      .fontWeight(opt.value === this.chatState.thinkingLevel ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(opt.value === this.chatState.thinkingLevel ? '#ECF3FF' : '#FFFFFF')
      .fontColor(opt.value === this.chatState.thinkingLevel ? '#1D5DD8' : '#4D5563')
      .borderRadius(12)
      .border({
        width: 1,
        color: opt.value === this.chatState.thinkingLevel ? '#1D5DD8' : '#D6DAE2'
      })
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .onClick(() => {
        this.nodeRuntime.getChatController()?.setThinkingLevel(opt.value);
      })
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text('SESSION')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4D5563')
        Blank()
        Row() {
          Text((this.chatState.healthOk || this.isConnected) ? $r('app.string.status_connected') : $r('app.string.status_offline'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor((this.chatState.healthOk || this.isConnected) ? '#2F8C5A' : '#C8841A')
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor((this.chatState.healthOk || this.isConnected) ? '#E8F5E9' : '#FFF8E8')
        .borderRadius(999)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.chatState.sessions.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.chatState.sessions, (entry: ChatSessionEntry) => {
              this.SessionChip(entry)
            }, (e: ChatSessionEntry) => e.key)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }

      Row({ space: 8 }) {
        ForEach(THINKING_OPTIONS, (opt: ThinkingOption) => {
          this.ThinkingChip(opt)
        }, (opt: ThinkingOption) => opt.value)
      }
      .width('100%')

      if (this.chatState.errorText) {
        Column({ space: 2 }) {
          Text($r('app.string.chat_error_header'))
            .fontSize(11)
            .fontColor('#dc3545')
          Text(this.chatState.errorText)
            .fontSize(14)
            .fontColor('#17181C')
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .border({ width: 1, color: '#dc3545' })
        .alignItems(HorizontalAlign.Start)
      }

      List({ scroller: this.listScroller, initialIndex: this.getListLastIndex(), space: 12 }) {
        if (!this.chatState.healthOk && this.chatState.messages.length === 0) {
          ListItem() {
            Column({ space: 4 }) {
              Text($r('app.string.chat_no_messages_yet'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.chat_connect_first_hint'))
                .fontSize(14)
                .fontColor('#4D5563')
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#FFFFFF')
            .borderRadius(14)
            .border({ width: 1, color: '#E5E7EC' })
            .alignItems(HorizontalAlign.Start)
          }
        }
        if (this.chatState.healthOk && this.chatState.messages.length === 0 &&
          !this.chatState.streamingAssistantText && this.chatState.pendingRunCount === 0) {
          ListItem() {
            Column({ space: 4 }) {
              Text($r('app.string.chat_no_messages_yet'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
              Text($r('app.string.chat_send_first_prompt'))
                .fontSize(14)
                .fontColor('#4D5563')
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#FFFFFF')
            .borderRadius(14)
            .border({ width: 1, color: '#E5E7EC' })
            .alignItems(HorizontalAlign.Start)
          }
        }
        ForEach(this.chatState.messages, (msg: ChatMessage) => {
          ListItem() {
            this.MessageBubble(msg, msg.role.trim().toLowerCase() === 'user')
          }
        }, (msg: ChatMessage) => msg.id)
        if (this.chatState.streamingAssistantText) {
          ListItem() {
            Row() {
              Column({ space: 3 }) {
                Text('ASSISTANT · LIVE')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#1D5DD8')
                Markdown({ text: this.chatState.streamingAssistantText || ' ', mode: 'text' })
              }
              .width('90%')
              .padding({ left: 11, right: 11, top: 8, bottom: 8 })
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: '#1D5DD8' })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
        }
        if (this.chatState.pendingRunCount > 0 && !this.chatState.streamingAssistantText) {
          ListItem() {
            Row() {
              Column({ space: 3 }) {
                Text('ASSISTANT')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#4D5563')
                Row({ space: 5 }) {
                  Text('●').fontSize(10).fontColor('#4D5563').opacity(0.4)
                  Text('●').fontSize(10).fontColor('#4D5563').opacity(0.6)
                  Text('●').fontSize(10).fontColor('#4D5563').opacity(0.9)
                  Text($r('app.string.chat_thinking'))
                    .fontSize(14)
                    .fontColor('#4D5563')
                }
              }
              .padding({ left: 11, right: 11, top: 8, bottom: 8 })
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: '#D6DAE2' })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
        }
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 0 })
      .scrollBar(BarState.Off)
      .padding({ bottom: 24 })

      Column({ space: 8 }) {
        Text('MESSAGE')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4D5563')

        TextInput({
          placeholder: $r('app.string.chat_input_placeholder'),
          text: this.inputText
        })
          .onChange((v) => { this.inputText = v; })
          .height(92)
          .width('100%')
          .backgroundColor('#F6F7FA')
          .borderRadius(14)
          .border({ width: 1, color: '#E5E7EC' })

        if (!this.chatState.healthOk) {
          Text($r('app.string.chat_gateway_offline_hint'))
            .fontSize(14)
            .fontColor('#C8841A')
        }

        Row({ space: 10 }) {
          Button($r('app.string.chat_refresh'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#FFFFFF')
            .fontColor('#4D5563')
            .borderRadius(14)
            .border({ width: 1, color: '#D6DAE2' })
            .height(48)
            .onClick(() => {
              const c = this.nodeRuntime.getChatController();
              if (c) {
                c.bootstrap();
                c.refreshSessions();
              }
            })
          Button($r('app.string.chat_abort'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#FFFFFF')
            .fontColor(this.chatState.pendingRunCount > 0 ? '#4D5563' : '#99A0AE')
            .borderRadius(14)
            .border({ width: 1, color: '#D6DAE2' })
            .height(48)
            .enabled(this.chatState.pendingRunCount > 0)
            .onClick(() => {
              this.nodeRuntime.getChatController()?.abort();
            })
          Button($r('app.string.chat_send'))
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .backgroundColor((this.chatState.healthOk || this.isConnected) && this.inputText.trim().length > 0 ? '#1D5DD8' : '#D6DAE2')
            .fontColor((this.chatState.healthOk || this.isConnected) && this.inputText.trim().length > 0 ? '#FFFFFF' : '#99A0AE')
            .borderRadius(14)
            .border({ width: 1, color: (this.chatState.healthOk || this.isConnected) && this.inputText.trim().length > 0 ? '#184DAF' : '#D6DAE2' })
            .enabled((this.chatState.healthOk || this.isConnected) && this.inputText.trim().length > 0)
            .onClick(() => {
              const text = this.inputText.trim();
              if (!text) return;
              const c = this.nodeRuntime.getChatController();
              if (c) {
                c.sendMessage(text, this.chatState.thinkingLevel);
                this.inputText = '';
              }
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#F7F8FA')
  }
}
