/**
 * Chat tab: matches Android ChatSheetContent structure and styling.
 * Session/connection row, error rail, message list with bubbles, composer.
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Markdown, MarkdownController } from '@luvi/lv-markdown-in';
import { NodeRuntime } from '../NodeRuntime';
import { CHAT_ATTACHMENT_MAX_COUNT, pickAndEncodeChatImages, toOutgoingImageAttachments } from '../chat/ChatImageAttach';
import type { ChatMessage, ChatMessageContent, ChatPendingAttachment, ChatPendingToolCall, ChatSessionEntry } from '../chat/ChatModels';
import { friendlyChipLabel, resolveSessionChoices, friendlySessionKeyLabel } from '../chat/SessionChips';
import { HMRouter, HMRouterMgr } from '@hadss/hmrouter';

export interface ChatTabState {
  messages: ChatMessage[];
  errorText: string | null;
  healthOk: boolean;
  streamingAssistantText: string | null;
  pendingRunCount: number;
  sessionKey: string;
  mainSessionKey: string;
  thinkingLevel: string;
  sessions: ChatSessionEntry[];
  pendingToolCalls: ChatPendingToolCall[];
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
    mainSessionKey: 'main',
    thinkingLevel: 'off',
    sessions: [],
    pendingToolCalls: [],
  };
  return s;
}

function roleLabel(role: string): string {
  const r = role.trim().toLowerCase();
  if (r === 'user') return 'USER';
  if (r === 'system') return 'SYSTEM';
  return 'ASSISTANT';
}

@HMRouter({
  pageUrl: 'chat',
})
@Component
export struct ChatTabScreen {
  @Prop isConnected: boolean;
  @Prop showBackButton?: boolean;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State chatState: ChatTabState = defaultChatTabState();
  @State inputText: string = '';
  @State pendingAttachments: ChatPendingAttachment[] = [];
  @State plusMenuVisible: boolean = false;
  private listScroller: ListScroller = new ListScroller();
  private prevScrollKey: string = '';
  // 获取对象
  markdownController: MarkdownController = new MarkdownController()

  /** Matches List children: optional empty row, then visible messages, then tools/stream/thinking rows. */
  private isConnectEmptyList(): boolean {
    const s = this.chatState;
    return !s.healthOk && s.messages.length === 0;
  }

  private isHealthyEmptyList(): boolean {
    const s = this.chatState;
    return s.healthOk && s.messages.length === 0 && !s.streamingAssistantText && s.pendingRunCount === 0 &&
      s.pendingToolCalls.length === 0;
  }

  private getChatListItemCount(): number {
    if (this.isConnectEmptyList() || this.isHealthyEmptyList()) {
      return 1;
    }
    const s = this.chatState;
    const v = this.visibleChatMessages().length;
    let n = v;
    if (s.pendingToolCalls.length > 0) {
      n++;
    }
    if (s.streamingAssistantText) {
      n++;
    }
    if (s.pendingRunCount > 0 && !s.streamingAssistantText) {
      n++;
    }
    return n;
  }

  private getChatListLastIndex(): number {
    const c = this.getChatListItemCount();
    return c > 0 ? c - 1 : 0;
  }

  /** Tab remount / layout: list may not be ready on first frame; retry a few times. */
  private scheduleScrollChatListToEnd(): void {
    const delays: number[] = [0, 80, 200, 450];
    for (let i = 0; i < delays.length; i++) {
      const d = delays[i];
      setTimeout(() => {
        this.scrollChatListToEnd(false);
      }, d);
    }
  }

  private scrollChatListToEnd(animate: boolean): void {
    const total = this.getChatListItemCount();
    const lastIdx = this.getChatListLastIndex();
    if (total <= 0 || lastIdx < 0 || lastIdx >= total) {
      return;
    }
    try {
      this.listScroller.scrollToIndex(lastIdx, animate, ScrollAlign.END);
    } catch {
      // List may not be attached yet
    }
  }

  aboutToUpdate(): void {
    const s = this.chatState;
    const vlen = this.visibleChatMessages().length;
    const streamLen = s.streamingAssistantText?.length ?? 0;
    const toolLen = s.pendingToolCalls.length;
    const key = `${s.sessionKey}-${s.messages.length}-${vlen}-${s.pendingRunCount}-${streamLen}-${toolLen}`;
    if (key !== this.prevScrollKey) {
      this.prevScrollKey = key;
      const total = this.getChatListItemCount();
      const lastIdx = this.getChatListLastIndex();
      if (total > 0 && lastIdx >= 0 && lastIdx < total) {
        setTimeout(() => {
          this.scrollChatListToEnd(true);
        }, 150);
      }
    }
  }

  private visibleChatMessages(): ChatMessage[] {
    const out: ChatMessage[] = [];
    for (let i = 0; i < this.chatState.messages.length; i++) {
      const msg = this.chatState.messages[i];
      if (this.hasDisplayableContent(msg)) {
        out.push(msg);
      }
    }
    return out;
  }

  aboutToAppear(): void {
    this.attachChatListener();
    this.scheduleScrollChatListToEnd();
    this.markdownController.setTextSize(12)
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
          mainSessionKey: state.mainSessionKey,
          thinkingLevel: state.thinkingLevel,
          sessions: state.sessions,
          pendingToolCalls: state.pendingToolCalls,
        };
        setTimeout(() => {
          this.chatState = next;
        }, 0);
      });
    }
  }

  private sessionChipRows(): ChatSessionEntry[] {
    return resolveSessionChoices(
      this.chatState.sessionKey,
      this.chatState.sessions,
      this.chatState.mainSessionKey,
    );
  }

  private filterDisplayableParts(parts: ChatMessageContent[]): ChatMessageContent[] {
    const out: ChatMessageContent[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      const typ = (p.type ?? 'text').trim();
      if (typ === 'text' && (p.text ?? '').trim().length > 0) {
        out.push(p);
      } else if ((p.base64 ?? '').trim().length > 0) {
        out.push(p);
      }
    }
    return out;
  }

  /** Filters noisy tool runtime traces from system chat rows. */
  private isNoisySystemText(msg: ChatMessage, text: string): boolean {
    const role = (msg.role ?? '').trim().toLowerCase();
    if (role !== 'system') {
      return false;
    }
    const t = text.trim();
    if (!t.startsWith('System: [')) {
      return false;
    }
    return t.includes('Exec completed') || t.includes('Connection refused') || t.includes('<urlopen error');
  }

  private filterDisplayableMessageParts(msg: ChatMessage): ChatMessageContent[] {
    const parts = this.filterDisplayableParts(msg.content);
    const out: ChatMessageContent[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if ((p.type ?? 'text').trim() !== 'text') {
        out.push(p);
        continue;
      }
      const txt = (p.text ?? '').trim();
      if (!txt) {
        continue;
      }
      if (!this.isNoisySystemText(msg, txt)) {
        out.push(p);
      }
    }
    return out;
  }

  private hasDisplayableContent(msg: ChatMessage): boolean {
    return this.filterDisplayableMessageParts(msg).length > 0;
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

  private canSendChat(): boolean {
    const online = this.chatState.healthOk || this.isConnected;
    const hasContent = this.inputText.trim().length > 0 || this.pendingAttachments.length > 0;
    return online && this.chatState.pendingRunCount === 0 && hasContent;
  }

  private canSendInputOnly(): boolean {
    const online = this.chatState.healthOk || this.isConnected;
    return online && this.chatState.pendingRunCount === 0 && this.inputText.trim().length > 0;
  }

  private sendCurrentMessage(): void {
    const text = this.inputText.trim();
    const hasAtt = this.pendingAttachments.length > 0;
    if (!text && !hasAtt) {
      return;
    }
    const c = this.nodeRuntime.getChatController();
    if (c) {
      const outgoing = hasAtt ? toOutgoingImageAttachments(this.pendingAttachments) : undefined;
      void c.sendMessage(text, this.chatState.thinkingLevel, outgoing);
      this.inputText = '';
      this.pendingAttachments = [];
      this.plusMenuVisible = false;
    }
  }

  private removePendingAttachment(id: string): void {
    const next: ChatPendingAttachment[] = [];
    for (let i = 0; i < this.pendingAttachments.length; i++) {
      if (this.pendingAttachments[i].id !== id) {
        next.push(this.pendingAttachments[i]);
      }
    }
    this.pendingAttachments = next;
  }

  private imagePartCaption(part: ChatMessageContent): string {
    const fn = (part.fileName ?? '').trim();
    const base = this.resStr($r('app.string.chat_attachment_image'));
    if (fn.length > 0) {
      return `📎 ${base}: ${fn}`;
    }
    return `📎 ${base}`;
  }

  @Builder
  MessagePartLine(_msg: ChatMessage, part: ChatMessageContent, index: number) {
    if ((part.type ?? 'text').trim() === 'text' && (part.text ?? '').trim().length > 0) {
      Markdown({ text: part.text ?? ' ', mode: 'text', controller: this.markdownController })
    } else if ((part.base64 ?? '').trim().length > 0) {
      Text(this.imagePartCaption(part))
        .fontSize(14)
        .fontColor('#4D5563')
    }
  }

  @Builder
  MessageBubble(msg: ChatMessage, isUser: boolean) {
    Row() {
      Column({ space: 8 }) {
        Text(roleLabel(msg.role))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(isUser ? '#1D5DD8' : '#4D5563')
        ForEach(this.filterDisplayableMessageParts(msg), (part: ChatMessageContent, index: number) => {
          this.MessagePartLine(msg, part, index);
        }, (part: ChatMessageContent, index: number) => `${msg.id}-${index}-${part.type}`)
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

  @Builder
  SessionChip(entry: ChatSessionEntry) {
    Button(friendlyChipLabel(entry))
      .fontSize(11)
      .fontWeight(entry.key === this.chatState.sessionKey ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(entry.key === this.chatState.sessionKey ? '#1D5DD8' : '#FFFFFF')
      .fontColor(entry.key === this.chatState.sessionKey ? '#FFFFFF' : '#17181C')
      .borderRadius(12)
      .border({
        width: 1,
        color: entry.key === this.chatState.sessionKey ? '#184DAF' : '#D6DAE2'
      })
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .onClick(() => {
        this.nodeRuntime.getChatController()?.load(entry.key);
      })
  }

  @Builder
  PendingToolsBubble(calls: ChatPendingToolCall[]) {
    Row() {
      Column({ space: 4 }) {
        Text($r('app.string.chat_tools_label'))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4D5563')
        Text($r('app.string.chat_tools_running'))
          .fontSize(12)
          .fontColor('#8A92A2')
        ForEach(calls, (tc: ChatPendingToolCall) => {
          Text(`· ${tc.name}`)
            .fontSize(13)
            .fontColor('#4D5563')
        }, (tc: ChatPendingToolCall) => tc.toolCallId)
      }
      .width('90%')
      .padding({ left: 11, right: 11, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
      .border({ width: 1, color: '#D6DAE2' })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  PendingAttachmentChip(att: ChatPendingAttachment) {
    Row({ space: 8 }) {
      Text(att.fileName)
        .fontSize(12)
        .fontColor('#17181C')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Button('×')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#4D5563')
        .backgroundColor('#FFFFFF')
        .borderRadius(999)
        .border({ width: 1, color: '#D6DAE2' })
        .height(28)
        .width(28)
        .padding(0)
        .onClick(() => {
          this.removePendingAttachment(att.id);
        })
    }
    .padding({ left: 10, right: 8, top: 6, bottom: 6 })
    .constraintSize({ minWidth: 120, maxWidth: 220 })
    .backgroundColor('#ECF3FF')
    .borderRadius(999)
    .border({ width: 1, color: '#D6DAE2' })
  }

  @Builder
  ThinkingChip(opt: ThinkingOption) {
    Button($r(opt.labelKey))
      .fontSize(11)
      .fontWeight(opt.value === this.chatState.thinkingLevel ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(opt.value === this.chatState.thinkingLevel ? '#ECF3FF' : '#FFFFFF')
      .fontColor(opt.value === this.chatState.thinkingLevel ? '#1D5DD8' : '#4D5563')
      .borderRadius(10)
      .border({
        width: 1,
        color: opt.value === this.chatState.thinkingLevel ? '#1D5DD8' : '#D6DAE2'
      })
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .onClick(() => {
        this.nodeRuntime.getChatController()?.setThinkingLevel(opt.value);
      })
  }

  build() {
    Column({ space: 4 }) {
      // Detail page custom navigation bar.
      Column({ space: 0 }) {
        Row() {
          Button($r('app.string.chat_back'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#FFFFFF')
            .fontColor('#4D5563')
            .borderRadius(14)
            .border({ width: 1, color: '#D6DAE2' })
            .height(40)
            .width(88)
            .onClick(() => {
              try {
                HMRouterMgr.pop();
              } catch {
                // best-effort
              }
            })

          Column() {
            Text(friendlySessionKeyLabel(this.chatState.sessionKey))
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#17181C')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text($r('app.string.chat_session_label'))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#4D5563')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .padding({ left: 10, right: 10 })

          Row() {
            Text((this.chatState.healthOk || this.isConnected) ? $r('app.string.status_connected') : $r('app.string.status_offline'))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor((this.chatState.healthOk || this.isConnected) ? '#2F8C5A' : '#C8841A')
          }
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor((this.chatState.healthOk || this.isConnected) ? '#E8F5E9' : '#FFF8E8')
          .borderRadius(999)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.SpaceBetween)

        // Temporarily hide thinking level controls in chat detail top bar.
        Row()
          .width('100%')
          .height(0)
          .visibility(Visibility.None)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .border({ width: 1, color: '#E5E7EC' })

      if (this.chatState.errorText) {
        Column({ space: 2 }) {
          Text($r('app.string.chat_error_header'))
            .fontSize(10)
            .fontColor('#dc3545')
          Text(this.chatState.errorText)
            .fontSize(12)
            .fontColor('#17181C')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .border({ width: 1, color: '#dc3545' })
        .alignItems(HorizontalAlign.Start)
      }

      List({ scroller: this.listScroller, initialIndex: this.getChatListLastIndex(), space: 8 }) {
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
          !this.chatState.streamingAssistantText && this.chatState.pendingRunCount === 0 &&
          this.chatState.pendingToolCalls.length === 0) {
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
        ForEach(this.visibleChatMessages(), (msg: ChatMessage) => {
          ListItem() {
            this.MessageBubble(msg, msg.role.trim().toLowerCase() === 'user')
          }
        }, (msg: ChatMessage) => msg.id)
        if (this.chatState.pendingToolCalls.length > 0) {
          ListItem() {
            this.PendingToolsBubble(this.chatState.pendingToolCalls)
          }
        }
        if (this.chatState.streamingAssistantText) {
          ListItem() {
            Row() {
              Column({ space: 3 }) {
                Text($r('app.string.chat_stream_live'))
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
      .padding({ bottom: 6 })
      .onClick(() => {
        if (this.plusMenuVisible) {
          this.plusMenuVisible = false;
        }
      })

      Column({ space: 4 }) {
        if (this.pendingAttachments.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.pendingAttachments, (att: ChatPendingAttachment) => {
                this.PendingAttachmentChip(att)
              }, (att: ChatPendingAttachment) => att.id)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        if (this.plusMenuVisible) {
          Row({ space: 6 }) {
            Button($r('app.string.chat_attach'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#FFFFFF')
              .fontColor(this.pendingAttachments.length < CHAT_ATTACHMENT_MAX_COUNT ? '#4D5563' : '#99A0AE')
              .borderRadius(12)
              .border({ width: 1, color: '#D6DAE2' })
              .height(38)
              .enabled(this.pendingAttachments.length < CHAT_ATTACHMENT_MAX_COUNT)
              .onClick(() => {
                const remain = CHAT_ATTACHMENT_MAX_COUNT - this.pendingAttachments.length;
                if (remain <= 0) {
                  try {
                    promptAction.showToast({ message: this.resStr($r('app.string.chat_attach_limit')) });
                  } catch {
                    // ignore
                  }
                  return;
                }
                const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
                void pickAndEncodeChatImages(ctx ?? null, remain).then((list: ChatPendingAttachment[]) => {
                  if (list.length === 0) {
                    return;
                  }
                  const next: ChatPendingAttachment[] = [];
                  for (let i = 0; i < this.pendingAttachments.length; i++) {
                    next.push(this.pendingAttachments[i]);
                  }
                  for (let j = 0; j < list.length; j++) {
                    next.push(list[j]);
                  }
                  this.pendingAttachments = next;
                }).catch(() => {
                  try {
                    promptAction.showToast({ message: this.resStr($r('app.string.chat_attach_failed')) });
                  } catch {
                    // ignore
                  }
                });
                this.plusMenuVisible = false;
              })
            Button($r('app.string.chat_refresh'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#FFFFFF')
              .fontColor('#4D5563')
              .borderRadius(12)
              .border({ width: 1, color: '#D6DAE2' })
              .height(38)
              .onClick(() => {
                const c = this.nodeRuntime.getChatController();
                if (c) {
                  void c.bootstrap({ sessionLimit: 200 });
                }
                this.plusMenuVisible = false;
              })
            Button($r('app.string.chat_abort'))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#FFFFFF')
              .fontColor(this.chatState.pendingRunCount > 0 ? '#4D5563' : '#99A0AE')
              .borderRadius(12)
              .border({ width: 1, color: '#D6DAE2' })
              .height(38)
              .enabled(this.chatState.pendingRunCount > 0)
              .onClick(() => {
                this.nodeRuntime.getChatController()?.abort();
                this.plusMenuVisible = false;
              })
          }
          .width('100%')
        }

        Row({ space: 6 }) {
          TextInput({
            placeholder: $r('app.string.chat_input_placeholder'),
            text: this.inputText
          })
            .onChange((v) => {
              this.inputText = v;
              if (v.trim().length > 0 && this.plusMenuVisible) {
                this.plusMenuVisible = false;
              }
            })
            .layoutWeight(1)
            .height(42)
            .backgroundColor('#F6F7FA')
            .borderRadius(12)
            .border({ width: 1, color: '#E5E7EC' })

          Button(this.inputText.trim().length > 0 ? $r('app.string.chat_send') : '+')
            .height(42)
            .width(58)
            .fontSize(this.inputText.trim().length > 0 ? 12 : 20)
            .fontWeight(FontWeight.Bold)
            .backgroundColor(this.inputText.trim().length > 0 ? (this.canSendInputOnly() ? '#1D5DD8' : '#D6DAE2') : '#FFFFFF')
            .fontColor(this.inputText.trim().length > 0 ? (this.canSendInputOnly() ? '#FFFFFF' : '#99A0AE') : '#4D5563')
            .borderRadius(12)
            .border({ width: 1, color: this.inputText.trim().length > 0 ? (this.canSendInputOnly() ? '#184DAF' : '#D6DAE2') : '#D6DAE2' })
            .enabled(this.inputText.trim().length > 0 ? this.canSendInputOnly() : true)
            .onClick(() => {
              if (this.inputText.trim().length > 0) {
                this.sendCurrentMessage();
                return;
              }
              this.plusMenuVisible = !this.plusMenuVisible;
            })
        }
        .width('100%')

        if (!this.chatState.healthOk) {
          Text($r('app.string.chat_gateway_offline_hint'))
            .fontSize(11)
            .fontColor('#C8841A')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#F7F8FA')
  }
}
