/**
 * Chat tab: matches Android ChatSheetContent structure and styling.
 * Session/connection row, error rail, message list with bubbles, composer.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { KeyboardAvoidMode } from '@ohos.arkui.UIContext';
import { Markdown, MarkdownController } from '@luvi/lv-markdown-in';
import { NodeRuntime } from '../NodeRuntime';
import { CHAT_ATTACHMENT_MAX_COUNT, pickAndEncodeChatImages, toOutgoingImageAttachments } from '../chat/ChatImageAttach';
import type { ChatMessage, ChatMessageContent, ChatPendingAttachment, ChatPendingToolCall, ChatSessionEntry } from '../chat/ChatModels';
import { friendlyChipLabel, resolveSessionChoices, friendlySessionKeyLabel } from '../chat/SessionChips';
import type { VoiceUiState } from '../voice/VoiceModels';
import { HMRouter, HMRouterMgr } from '@hadss/hmrouter';

const CHAT_INLINE_IMAGE_MAX_EDGE = 1280;
const CHAT_INLINE_IMAGE_MAX_HEIGHT = 240;

function defaultVoiceUiState(): VoiceUiState {
  const s: VoiceUiState = {
    micEnabled: false,
    micCooldown: false,
    isSpeaking: false,
    speakerEnabled: true,
    talkModeEnabled: false,
    canCancel: false,
    liveTranscript: '',
    queuedMessages: [],
    conversation: [],
    isSending: false,
    activityLabel: 'Mic off',
    statusDetail: 'Mic off',
  };
  return s;
}

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

interface ToolSummaryRow {
  icon: string;
  label: string;
  detailLine: string | null;
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
  if (r === 'user') return 'You';
  if (r === 'system') return 'System';
  return 'OpenClaw';
}

function titleCaseWords(raw: string): string {
  const text = raw.trim();
  if (text.length === 0) {
    return 'Tool';
  }
  const parts = text.replace(/[_-]+/g, ' ').split(/\s+/);
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const word = parts[i];
    if (word.length === 0) {
      continue;
    }
    const upper = word.toUpperCase();
    if (word.length <= 2 && word === upper) {
      out.push(word);
      continue;
    }
    out.push(word.charAt(0).toUpperCase() + word.slice(1).toLowerCase());
  }
  return out.join(' ');
}

@HMRouter({
  pageUrl: 'chat',
})
@Component
export struct ChatTabScreen {
  @Prop isConnected: boolean;
  @Prop showBackButton: boolean = true;
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State chatState: ChatTabState = defaultChatTabState();
  @State voiceState: VoiceUiState = defaultVoiceUiState();
  @State hasMicPermission: boolean = false;
  @State voicePanelExpanded: boolean = false;
  @State inputText: string = '';
  @State pendingAttachments: ChatPendingAttachment[] = [];
  @State plusMenuVisible: boolean = false;
  @State inlineImageVersion: number = 0;
  @State previewImageKey: string = '';
  @State previewImageTitle: string = '';
  @State shouldAutoFollowChat: boolean = true;
  @State showJumpToLatest: boolean = false;
  @State composerFocused: boolean = false;
  private chatListenerId: number = -1;
  private listScroller: ListScroller = new ListScroller();
  private prevStructureScrollKey: string = '';
  private prevStreamScrollKey: string = '';
  private prevSessionKey: string = '';
  private lastVisibleChatIndex: number = -1;
  private autoFollowPinnedUntil: number = 0;
  private inlineImageCache = new Map<string, image.PixelMap | null>();
  private inlineImageLoading = new Set<string>();
  private inlineImageFailed = new Set<string>();
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
    this.pinAutoFollow(false);
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
    this.pinAutoFollow(animate);
    try {
      this.listScroller.scrollToIndex(lastIdx, animate, ScrollAlign.END);
    } catch {
      // List may not be attached yet
    }
  }

  aboutToUpdate(): void {
    const s = this.chatState;
    if (s.sessionKey !== this.prevSessionKey) {
      this.prevSessionKey = s.sessionKey;
      this.lastVisibleChatIndex = -1;
      this.pinAutoFollow(false);
    }
    const vlen = this.visibleChatMessages().length;
    const streamLen = s.streamingAssistantText?.length ?? 0;
    const toolLen = s.pendingToolCalls.length;
    const structureKey = `${s.sessionKey}-${s.messages.length}-${vlen}-${s.pendingRunCount}-${toolLen}`;
    if (structureKey !== this.prevStructureScrollKey) {
      this.prevStructureScrollKey = structureKey;
      if (this.shouldAutoFollowChat) {
        const total = this.getChatListItemCount();
        const lastIdx = this.getChatListLastIndex();
        if (total > 0 && lastIdx >= 0 && lastIdx < total) {
          setTimeout(() => {
            this.scrollChatListToEnd(true);
          }, 150);
        }
      }
    }

    const streamKey = `${s.sessionKey}-${streamLen}`;
    if (streamKey !== this.prevStreamScrollKey) {
      this.prevStreamScrollKey = streamKey;
      if (streamLen > 0 && this.shouldAutoFollowChat) {
        setTimeout(() => {
          this.scrollChatListToEnd(false);
        }, 0);
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
    this.attachVoiceListener();
    this.refreshMicPermission();
    this.scheduleScrollChatListToEnd();
    this.markdownController.setTextSize(12);
    this.nodeRuntime.setVoiceScreenActive(true);
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch {
      // best-effort
    }
  }

  onPageShow(): void {
    this.refreshMicPermission();
    this.nodeRuntime.setVoiceScreenActive(true);
  }

  aboutToDisappear(): void {
    const chat = this.nodeRuntime.getChatController();
    if (chat && this.chatListenerId >= 0) {
      chat.removeListener(this.chatListenerId);
      this.chatListenerId = -1;
    }
    if (this.voiceState.micEnabled) {
      void this.nodeRuntime.setVoiceMicEnabled(false);
    }
    if (this.voiceState.talkModeEnabled) {
      void this.nodeRuntime.setTalkModeEnabled(false);
    }
    this.nodeRuntime.setVoiceUiListener(null);
    this.nodeRuntime.setVoiceScreenActive(false);
    this.closeImagePreview();
    this.releaseAllInlineImages();
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    } catch {
      // best-effort
    }
  }

  private attachChatListener(): void {
    const chat = this.nodeRuntime.getChatController();
    if (!chat || this.chatListenerId >= 0) {
      return;
    }
    this.chatListenerId = chat.addListener((state) => {
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

  private attachVoiceListener(): void {
    this.nodeRuntime.setVoiceUiListener((state: VoiceUiState) => {
      setTimeout(() => {
        this.voiceState = state;
      }, 0);
    });
  }

  private sessionChipRows(): ChatSessionEntry[] {
    return resolveSessionChoices(
      this.chatState.sessionKey,
      this.chatState.sessions,
      this.chatState.mainSessionKey,
    );
  }

  private currentSessionEntry(): ChatSessionEntry | null {
    for (let i = 0; i < this.chatState.sessions.length; i++) {
      const entry = this.chatState.sessions[i];
      if (entry.key === this.chatState.sessionKey) {
        return entry;
      }
    }
    return null;
  }

  private currentSessionTitle(): string {
    const entry = this.currentSessionEntry();
    if (entry) {
      return friendlyChipLabel(entry);
    }
    const key = this.chatState.sessionKey.trim();
    return friendlySessionKeyLabel(key.length > 0 ? key : 'main');
  }

  private refreshMicPermission(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      this.hasMicPermission = false;
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    try {
      const tokenId = ctx.applicationInfo.accessTokenId;
      const status = at.checkAccessTokenSync(tokenId, 'ohos.permission.MICROPHONE');
      this.hasMicPermission = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch {
      this.hasMicPermission = false;
    }
  }

  private async requestMicAndEnable(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    const mic: Permissions = 'ohos.permission.MICROPHONE';
    try {
      const result = await at.requestPermissionsFromUser(ctx, [mic]);
      const granted =
        result.authResults.length > 0 &&
        result.authResults.every((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
      this.hasMicPermission = granted;
      if (granted) {
        this.refreshMicPermission();
        this.nodeRuntime.setVoiceScreenActive(true);
        await this.nodeRuntime.setVoiceMicEnabled(true);
      }
    } catch {
      this.hasMicPermission = false;
    }
  }

  private openAppSettings(): void {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    try {
      void ctx.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
      });
    } catch {
      // best-effort
    }
  }

  private voicePanelVisible(): boolean {
    return this.voicePanelExpanded ||
      this.voiceState.talkModeEnabled ||
      this.voiceState.micEnabled ||
      this.voiceState.micCooldown ||
      this.voiceState.isSpeaking ||
      this.voiceState.isSending ||
      this.voiceState.canCancel ||
      this.voiceState.liveTranscript.trim().length > 0;
  }

  private voiceStatusChipBackground(): string {
    if (this.voiceState.talkModeEnabled) {
      return '#E8F5E9';
    }
    if (this.voiceState.micEnabled) {
      return '#E8F5E9';
    }
    if (this.voiceState.isSpeaking) {
      return '#FFF4E5';
    }
    if (this.voiceState.isSending) {
      return '#ECF3FF';
    }
    if (this.voiceState.micCooldown) {
      return '#FFF4E5';
    }
    return '#F6F7FA';
  }

  private voiceStatusChipBorder(): string {
    if (this.voiceState.talkModeEnabled) {
      return 'rgba(47, 140, 90, 0.28)';
    }
    if (this.voiceState.micEnabled) {
      return 'rgba(47, 140, 90, 0.28)';
    }
    if (this.voiceState.isSpeaking) {
      return 'rgba(200, 132, 26, 0.24)';
    }
    if (this.voiceState.isSending) {
      return 'rgba(29, 93, 216, 0.24)';
    }
    if (this.voiceState.micCooldown) {
      return 'rgba(200, 132, 26, 0.24)';
    }
    return '#E5E7EC';
  }

  private voiceStatusChipTextColor(): string {
    if (this.voiceState.talkModeEnabled) {
      return '#2F8C5A';
    }
    if (this.voiceState.micEnabled) {
      return '#2F8C5A';
    }
    if (this.voiceState.isSpeaking) {
      return '#C8841A';
    }
    if (this.voiceState.isSending) {
      return '#1D5DD8';
    }
    if (this.voiceState.micCooldown) {
      return '#C8841A';
    }
    return '#4D5563';
  }

  private voiceMicButtonBackground(): string {
    if (this.voiceState.micCooldown) {
      return '#D6DAE2';
    }
    if (this.voiceState.isSpeaking) {
      return '#FFF4E5';
    }
    if (this.voiceState.canCancel && !this.voiceState.micEnabled) {
      return '#FFF1F3';
    }
    return this.voiceState.micEnabled ? '#dc3545' : '#FFFFFF';
  }

  private voiceMicButtonBorder(): string {
    if (this.voiceState.micEnabled) {
      return '#C53143';
    }
    if (this.voiceState.isSpeaking) {
      return '#F1D9A8';
    }
    if (this.voiceState.micCooldown) {
      return '#D6DAE2';
    }
    if (this.voiceState.canCancel) {
      return '#F3C7CE';
    }
    return '#D6DAE2';
  }

  private voiceMicButtonIconColor(): string {
    if (this.voiceState.micEnabled) {
      return '#FFFFFF';
    }
    if (this.voiceState.isSpeaking) {
      return '#C8841A';
    }
    if (this.voiceState.micCooldown) {
      return '#99A0AE';
    }
    if (this.voiceState.canCancel) {
      return '#dc3545';
    }
    return '#1D5DD8';
  }

  private voiceHintText(): string {
    if (!this.hasMicPermission) {
      return this.resStr($r('app.string.voice_mic_permission_rationale'));
    }
    if (this.voiceState.liveTranscript.trim().length > 0) {
      return this.voiceState.liveTranscript.trim();
    }
    if (this.voiceState.micEnabled) {
      return this.resStr($r('app.string.voice_hint_mic_stop_send'));
    }
    if (this.voiceState.isSpeaking) {
      return 'Assistant is speaking. Tap the mic to interrupt.';
    }
    if (this.voiceState.micCooldown) {
      return 'Finishing capture…';
    }
    if (this.voiceState.isSending) {
      return 'Sending your voice turn…';
    }
    if (this.voiceState.talkModeEnabled) {
      return 'Talk mode stays ready for the next turn.';
    }
    const detail = this.voiceState.statusDetail.trim();
    if (detail.length > 0 && detail !== 'Mic off') {
      return detail;
    }
    return this.resStr($r('app.string.voice_hint_tap_mic'));
  }

  private voiceAuxiliaryText(): string {
    const detail = this.voiceState.statusDetail.trim();
    const activity = this.voiceState.activityLabel.trim();
    if (detail.length === 0 || detail === activity || detail === this.voiceHintText()) {
      return '';
    }
    return detail;
  }

  private async cancelVoiceSend(): Promise<void> {
    this.voicePanelExpanded = false;
    await this.nodeRuntime.cancelVoicePendingTurn();
  }

  private async requestMicAndEnableTalkMode(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    const at = abilityAccessCtrl.createAtManager();
    const mic: Permissions = 'ohos.permission.MICROPHONE';
    try {
      const result = await at.requestPermissionsFromUser(ctx, [mic]);
      const granted =
        result.authResults.length > 0 &&
        result.authResults.every((r) => r === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED);
      this.hasMicPermission = granted;
      if (granted) {
        this.refreshMicPermission();
        this.nodeRuntime.setVoiceScreenActive(true);
        await this.nodeRuntime.setTalkModeEnabled(true);
      }
    } catch {
      this.hasMicPermission = false;
    }
  }

  private async toggleTalkMode(): Promise<void> {
    this.plusMenuVisible = false;
    this.voicePanelExpanded = true;
    this.refreshMicPermission();
    this.nodeRuntime.setVoiceScreenActive(true);
    if (this.voiceState.talkModeEnabled) {
      await this.nodeRuntime.setTalkModeEnabled(false);
      return;
    }
    if (this.hasMicPermission) {
      await this.nodeRuntime.setTalkModeEnabled(true);
      return;
    }
    await this.requestMicAndEnableTalkMode();
  }

  private async toggleVoiceMic(): Promise<void> {
    if (this.voiceState.micCooldown) {
      return;
    }
    this.plusMenuVisible = false;
    this.voicePanelExpanded = true;
    this.refreshMicPermission();
    this.nodeRuntime.setVoiceScreenActive(true);
    if (this.voiceState.micEnabled) {
      await this.nodeRuntime.setVoiceMicEnabled(false);
      return;
    }
    if (this.voiceState.isSpeaking) {
      if (this.hasMicPermission) {
        await this.nodeRuntime.setVoiceMicEnabled(true);
      } else {
        await this.requestMicAndEnable();
      }
      return;
    }
    if (this.voiceState.canCancel) {
      await this.cancelVoiceSend();
      return;
    }
    if (this.hasMicPermission) {
      await this.nodeRuntime.setVoiceMicEnabled(true);
      return;
    }
    await this.requestMicAndEnable();
  }

  @Builder
  ChatHeader() {
    Column({ space: 0 }) {
      Row() {
        if (this.showBackButton) {
          Button() {
            Row({ space: 4 }) {
              Text('‹')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#17181C')
              Text(this.resStr($r('app.string.chat_back')))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#17181C')
            }
            .alignItems(VerticalAlign.Center)
          }
          .backgroundColor('#00000000')
          .borderRadius(999)
          .height(36)
          .padding({ left: 2, right: 8 })
          .onClick(() => {
            try {
              HMRouterMgr.pop();
            } catch {
              // best-effort
            }
          })
        }

        Column() {
          Text(this.currentSessionTitle())
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#17181C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .padding({ left: this.showBackButton ? 8 : 0, right: 10 })
        .alignItems(HorizontalAlign.Start)

        Row() {
          Text((this.chatState.healthOk || this.isConnected) ? $r('app.string.status_connected') : $r('app.string.status_offline'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor((this.chatState.healthOk || this.isConnected) ? '#2F8C5A' : '#C8841A')
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor((this.chatState.healthOk || this.isConnected) ? '#E8F5E9' : '#FFF8E8')
        .borderRadius(999)
        .border({ width: 1, color: (this.chatState.healthOk || this.isConnected) ? '#CDE8D2' : '#F1D9A8' })
      }
      .width('100%')
      .height(52)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween)

      Row()
        .width('100%')
        .height(1)
        .backgroundColor('#E9EDF3')
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  VoiceComposerTray() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.voiceState.micEnabled ? $r('sys.symbol.mic_fill') :
            (this.voiceState.isSpeaking ? $r('sys.symbol.speaker_fill') : $r('sys.symbol.mic_slash_fill')))
            .fontSize(15)
            .fontColor([this.voiceStatusChipTextColor()])
          Text(this.voiceState.activityLabel)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.voiceStatusChipTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.voiceStatusChipBackground())
        .borderRadius(999)
        .border({ width: 1, color: this.voiceStatusChipBorder() })

        Blank()

        Button() {
          SymbolGlyph(this.voiceState.speakerEnabled ? $r('sys.symbol.speaker_fill') :
            $r('sys.symbol.speaker_slash_fill'))
            .fontSize(16)
            .fontColor([this.voiceState.speakerEnabled ? '#1D5DD8' : '#8A92A2'])
        }
        .width(34)
        .height(34)
        .backgroundColor(this.voiceState.speakerEnabled ? '#ECF3FF' : '#F6F7FA')
        .borderRadius(17)
        .border({ width: 1, color: this.voiceState.speakerEnabled ? '#CFE0FF' : '#E5E7EC' })
        .onClick(() => {
          void this.nodeRuntime.setVoiceSpeakerEnabled(!this.voiceState.speakerEnabled);
        })

        Button(this.voiceState.talkModeEnabled ? 'Talk on' : 'Talk')
          .height(34)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.voiceState.talkModeEnabled ? '#E8F5E9' : '#F6F7FA')
          .fontColor(this.voiceState.talkModeEnabled ? '#2F8C5A' : '#4D5563')
          .borderRadius(17)
          .border({ width: 1, color: this.voiceState.talkModeEnabled ? '#CDE8D2' : '#E5E7EC' })
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            void this.toggleTalkMode();
          })

        if (!this.voiceState.micEnabled && !this.voiceState.isSending && !this.voiceState.micCooldown) {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(16)
              .fontColor(['#8A92A2'])
          }
          .width(34)
          .height(34)
          .backgroundColor('#F6F7FA')
          .borderRadius(17)
          .border({ width: 1, color: '#E5E7EC' })
          .onClick(() => {
            this.voicePanelExpanded = false;
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.voiceHintText())
        .fontSize(13)
        .fontColor(this.hasMicPermission ? '#17181C' : '#C8841A')
        .width('100%')

      if (this.voiceAuxiliaryText().length > 0) {
        Text(this.voiceAuxiliaryText())
          .fontSize(11)
          .fontColor('#8A92A2')
          .width('100%')
      }

      if (this.voiceState.canCancel) {
        Button('Cancel')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#dc3545')
          .backgroundColor('#FFF1F3')
          .borderRadius(12)
          .border({ width: 1, color: '#F3C7CE' })
          .height(36)
          .width('100%')
          .onClick(() => {
            void this.cancelVoiceSend();
          })
      }

      if (!this.hasMicPermission) {
        Button(this.resStr($r('app.string.voice_open_settings')))
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#4D5563')
          .borderRadius(12)
          .height(36)
          .width('100%')
          .onClick(() => {
            this.openAppSettings();
          })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
    .border({ width: 1, color: '#E5E7EC' })
    .alignItems(HorizontalAlign.Start)
  }

  private toolLabel(name: string): string {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return 'Tool';
    }
    return titleCaseWords(trimmed);
  }

  private toolIcon(name: string): string {
    const key = name.trim().toLowerCase();
    if (key.includes('read')) return '📖';
    if (key.includes('write') || key.includes('edit')) return '✍';
    if (key.includes('search') || key.includes('find')) return '🔎';
    if (key.includes('fetch') || key.includes('open')) return '🌐';
    if (key.includes('image') || key.includes('screenshot') || key.includes('camera')) return '🖼';
    if (key.includes('notify')) return '🔔';
    if (key.includes('location') || key.includes('map')) return '📍';
    if (key.includes('run') || key.includes('exec') || key.includes('command')) return '⌘';
    return '🧩';
  }

  private renderToolArgValue(value: object | string | number | boolean | null): string | null {
    if (value === null) {
      return null;
    }
    if (typeof value === 'string') {
      const singleLine = value.replace(/\s+/g, ' ').trim();
      if (singleLine.length === 0) {
        return null;
      }
      return singleLine.length > 160 ? `${singleLine.slice(0, 157)}…` : singleLine;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    if (Array.isArray(value)) {
      const out: string[] = [];
      for (let i = 0; i < value.length && out.length < 3; i++) {
        const rendered = this.renderToolArgValue(value[i] as object | string | number | boolean | null);
        if (rendered && rendered.length > 0) {
          out.push(rendered);
        }
      }
      if (out.length === 0) {
        return null;
      }
      return out.join(', ');
    }
    const record = value as Record<string, object | string | number | boolean | null>;
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const rendered = this.renderToolArgValue(record[keys[i]]);
      if (rendered && rendered.length > 0) {
        return rendered;
      }
    }
    return null;
  }

  private toolArgPath(args: Record<string, object | string | number | boolean | null> | null, keyPath: string): string | null {
    if (!args) {
      return null;
    }
    const parts = keyPath.split('.');
    let current: object | string | number | boolean | null = args;
    for (let i = 0; i < parts.length; i++) {
      if (current === null || typeof current !== 'object' || Array.isArray(current)) {
        return null;
      }
      const record = current as Record<string, object | string | number | boolean | null>;
      current = record[parts[i]] ?? null;
    }
    return this.renderToolArgValue(current);
  }

  private firstToolDetail(args: Record<string, object | string | number | boolean | null> | null, keys: string[]): string | null {
    for (let i = 0; i < keys.length; i++) {
      const rendered = this.toolArgPath(args, keys[i]);
      if (rendered && rendered.length > 0) {
        return rendered;
      }
    }
    return null;
  }

  private toolSummary(tc: ChatPendingToolCall): ToolSummaryRow {
    const name = tc.name.trim();
    const key = name.toLowerCase();
    let detail = this.firstToolDetail(tc.args, [
      'path',
      'url',
      'query',
      'text',
      'prompt',
      'message',
      'title',
      'name',
      'location',
      'fileName',
      'subject',
    ]);
    if (key === 'read') {
      const path = this.toolArgPath(tc.args, 'path');
      const offset = this.toolArgPath(tc.args, 'offset');
      const limit = this.toolArgPath(tc.args, 'limit');
      if (path && offset && limit) {
        detail = `${path}:${offset}-${limit}`;
      } else if (path) {
        detail = path;
      }
    }
    if (detail === null) {
      detail = this.firstToolDetail(tc.args, [
        'args.path',
        'args.url',
        'args.query',
        'args.location',
        'args.text',
        'args.message',
      ]);
    }
    return {
      icon: this.toolIcon(name),
      label: this.toolLabel(name),
      detailLine: detail,
    };
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
    const online = this.chatState.healthOk;
    const hasContent = this.inputText.trim().length > 0 || this.pendingAttachments.length > 0;
    return online && this.chatState.pendingRunCount === 0 && hasContent;
  }

  private hasComposerContent(): boolean {
    return this.inputText.trim().length > 0 || this.pendingAttachments.length > 0;
  }

  private pinAutoFollow(animate: boolean): void {
    this.shouldAutoFollowChat = true;
    this.showJumpToLatest = false;
    this.autoFollowPinnedUntil = Date.now() + (animate ? 480 : 180);
  }

  private isChatViewportNearEnd(endIndex: number): boolean {
    const lastIdx = this.getChatListLastIndex();
    if (lastIdx <= 0) {
      return true;
    }
    return endIndex >= Math.max(0, lastIdx - 1);
  }

  private refreshAutoFollowState(endIndex?: number): void {
    if (this.composerFocused) {
      this.shouldAutoFollowChat = true;
      this.showJumpToLatest = false;
      return;
    }
    if (typeof endIndex === 'number' && endIndex >= 0) {
      this.lastVisibleChatIndex = endIndex;
    }
    let nearEnd = this.isChatViewportNearEnd(this.lastVisibleChatIndex);
    try {
      if (this.listScroller.isAtEnd()) {
        nearEnd = true;
      }
    } catch {
      // List may not be attached yet.
    }
    if (nearEnd) {
      this.shouldAutoFollowChat = true;
      this.showJumpToLatest = false;
      return;
    }
    if (Date.now() < this.autoFollowPinnedUntil) {
      return;
    }
    this.shouldAutoFollowChat = false;
    this.showJumpToLatest = true;
  }

  private clearPendingAttachmentPreviews(): void {
    for (let i = 0; i < this.pendingAttachments.length; i++) {
      this.releaseInlineImage(this.attachmentPreviewKey(this.pendingAttachments[i]));
    }
  }

  private sendCurrentMessage(): void {
    const text = this.inputText.trim();
    const hasAtt = this.pendingAttachments.length > 0;
    if ((!text && !hasAtt) || !this.canSendChat()) {
      return;
    }
    const c = this.nodeRuntime.getChatController();
    if (c) {
      this.pinAutoFollow(false);
      const outgoing = hasAtt ? toOutgoingImageAttachments(this.pendingAttachments) : undefined;
      void c.sendMessage(text, this.chatState.thinkingLevel, outgoing);
      this.inputText = '';
      this.clearPendingAttachmentPreviews();
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

  private inlineImageKey(messageId: string, part: ChatMessageContent, index: number): string {
    const name = (part.fileName ?? '').trim();
    const mime = (part.mimeType ?? '').trim().toLowerCase();
    return `${messageId}:${index}:${mime}:${name}`;
  }

  private attachmentPreviewKey(att: ChatPendingAttachment): string {
    return `pending:${att.id}`;
  }

  private releaseInlineImage(key: string): void {
    const pixelMap = this.inlineImageCache.get(key);
    if (pixelMap) {
      try {
        pixelMap.release();
      } catch {
        // ignore
      }
    }
    this.inlineImageCache.delete(key);
    this.inlineImageLoading.delete(key);
    this.inlineImageFailed.delete(key);
  }

  private releaseAllInlineImages(): void {
    const keys = Array.from(this.inlineImageCache.keys());
    for (let i = 0; i < keys.length; i++) {
      this.releaseInlineImage(keys[i]);
    }
    this.inlineImageLoading.clear();
    this.inlineImageFailed.clear();
  }

  private base64ToArrayBuffer(base64: string): ArrayBuffer | null {
    const text = (base64 ?? '').trim();
    if (text.length === 0) {
      return null;
    }
    try {
      const helper = new util.Base64Helper();
      const decoded = helper.decodeSync(text);
      const copy = new Uint8Array(decoded.length);
      copy.set(decoded);
      return copy.buffer;
    } catch {
      return null;
    }
  }

  private async decodeInlineImage(base64: string): Promise<image.PixelMap | null> {
    const raw = this.base64ToArrayBuffer(base64);
    if (!raw) {
      return null;
    }
    let src: image.ImageSource | null = null;
    try {
      src = image.createImageSource(raw);
      const info = await src.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;
      if (w <= 0 || h <= 0) {
        return null;
      }
      const longEdge = Math.max(w, h);
      let targetWidth = w;
      let targetHeight = h;
      if (longEdge > CHAT_INLINE_IMAGE_MAX_EDGE) {
        const scale = CHAT_INLINE_IMAGE_MAX_EDGE / longEdge;
        targetWidth = Math.max(1, Math.floor(w * scale));
        targetHeight = Math.max(1, Math.floor(h * scale));
      }
      return await src.createPixelMap({
        desiredSize: {
          width: targetWidth,
          height: targetHeight,
        },
      });
    } catch {
      return null;
    } finally {
      if (src) {
        try {
          src.release();
        } catch {
          // ignore
        }
      }
    }
  }

  private ensureInlineImageLoaded(cacheKey: string, base64: string): void {
    if (this.inlineImageCache.has(cacheKey) || this.inlineImageLoading.has(cacheKey) || this.inlineImageFailed.has(cacheKey)) {
      return;
    }
    this.inlineImageLoading.add(cacheKey);
    void this.decodeInlineImage(base64).then((pixelMap) => {
      this.inlineImageLoading.delete(cacheKey);
      if (pixelMap) {
        const prev = this.inlineImageCache.get(cacheKey);
        if (prev && prev !== pixelMap) {
          try {
            prev.release();
          } catch {
            // ignore
          }
        }
        this.inlineImageCache.set(cacheKey, pixelMap);
        this.inlineImageFailed.delete(cacheKey);
      } else {
        this.inlineImageCache.delete(cacheKey);
        this.inlineImageFailed.add(cacheKey);
      }
      this.inlineImageVersion += 1;
    }).catch(() => {
      this.inlineImageLoading.delete(cacheKey);
      this.inlineImageCache.delete(cacheKey);
      this.inlineImageFailed.add(cacheKey);
      this.inlineImageVersion += 1;
    });
  }

  private imagePreviewLabel(part: ChatMessageContent): string {
    const fn = (part.fileName ?? '').trim();
    if (fn.length > 0) {
      return fn;
    }
    return this.resStr($r('app.string.chat_attachment_image'));
  }

  private hasInlineImagePreview(cacheKey: string): boolean {
    return this.inlineImageCache.has(cacheKey) && this.inlineImageCache.get(cacheKey) !== null;
  }

  private inlineImagePreview(cacheKey: string): image.PixelMap | null {
    return this.inlineImageCache.get(cacheKey) ?? null;
  }

  private openImagePreview(cacheKey: string, title: string): void {
    if (!this.hasInlineImagePreview(cacheKey)) {
      return;
    }
    this.previewImageKey = cacheKey;
    this.previewImageTitle = title;
  }

  private closeImagePreview(): void {
    this.previewImageKey = '';
    this.previewImageTitle = '';
  }

  private isPreviewVisible(): boolean {
    return this.previewImageKey.length > 0 && this.hasInlineImagePreview(this.previewImageKey);
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
  MessagePartLine(msg: ChatMessage, part: ChatMessageContent, index: number) {
    if ((part.type ?? 'text').trim() === 'text' && (part.text ?? '').trim().length > 0) {
      Markdown({ text: part.text ?? ' ', mode: 'text', controller: this.markdownController })
    } else if ((part.base64 ?? '').trim().length > 0) {
      Column({ space: 6 }) {
        if (this.hasInlineImagePreview(this.inlineImageKey(msg.id, part, index))) {
          Image(this.inlineImagePreview(this.inlineImageKey(msg.id, part, index)))
            .width('100%')
            .constraintSize({ minHeight: 96, maxHeight: CHAT_INLINE_IMAGE_MAX_HEIGHT })
            .borderRadius(10)
            .objectFit(ImageFit.Contain)
            .backgroundColor('#F6F7FA')
            .onClick(() => {
              this.openImagePreview(this.inlineImageKey(msg.id, part, index), this.imagePreviewLabel(part));
            })
        } else {
          Row({ space: 6 }) {
            Text('▣')
              .fontSize(14)
              .fontColor('#8A92A2')
            Text(this.imagePartCaption(part))
              .fontSize(13)
              .fontColor('#4D5563')
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          .backgroundColor('#F6F7FA')
          .borderRadius(10)
        }

        Text(this.imagePreviewLabel(part))
          .fontSize(12)
          .fontColor('#6B7280')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .onAppear(() => {
        this.ensureInlineImageLoaded(this.inlineImageKey(msg.id, part, index), part.base64 ?? '');
      })
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
          Column({ space: 2 }) {
            Text(`${this.toolSummary(tc).icon} ${this.toolSummary(tc).label}`)
              .fontSize(13)
              .fontColor('#4D5563')
            if (this.toolSummary(tc).detailLine) {
              Text(this.toolSummary(tc).detailLine ?? '')
                .fontSize(11)
                .fontColor('#8A92A2')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
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
      if (this.hasInlineImagePreview(this.attachmentPreviewKey(att))) {
        Image(this.inlineImagePreview(this.attachmentPreviewKey(att)))
          .width(44)
          .height(44)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#F6F7FA')
          .onClick(() => {
            this.openImagePreview(this.attachmentPreviewKey(att), att.fileName);
          })
      } else {
        Row() {
          Text('▣')
            .fontSize(16)
            .fontColor('#8A92A2')
        }
        .width(44)
        .height(44)
        .borderRadius(10)
        .backgroundColor('#F6F7FA')
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 2 }) {
        Text(att.fileName)
          .fontSize(12)
          .fontColor('#17181C')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.resStr($r('app.string.chat_attachment_image')))
          .fontSize(10)
          .fontColor('#6B7280')
      }
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
          this.releaseInlineImage(this.attachmentPreviewKey(att));
          this.removePendingAttachment(att.id);
        })
    }
    .padding({ left: 10, right: 8, top: 6, bottom: 6 })
    .constraintSize({ minWidth: 180, maxWidth: 240 })
    .backgroundColor('#ECF3FF')
    .borderRadius(16)
    .border({ width: 1, color: '#D6DAE2' })
    .onAppear(() => {
      this.ensureInlineImageLoaded(this.attachmentPreviewKey(att), att.base64);
    })
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

  @Builder
  JumpToLatestButton() {
    Button($r('app.string.chat_jump_to_latest'))
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .backgroundColor('#1D5DD8')
      .borderRadius(999)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .shadow({ radius: 12, color: '#3317181C', offsetX: 0, offsetY: 4 })
      .onClick(() => {
        this.scrollChatListToEnd(true);
      })
  }

  @Builder
  ImagePreviewOverlay() {
    Column({ space: 16 }) {
      Row() {
        Text(this.previewImageTitle)
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('×')
          .width(36)
          .height(36)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor('#1F293799')
          .borderRadius(999)
          .padding(0)
          .onClick(() => {
            this.closeImagePreview();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isPreviewVisible()) {
        Image(this.inlineImagePreview(this.previewImageKey))
          .width('100%')
          .layoutWeight(1)
          .objectFit(ImageFit.Contain)
          .borderRadius(14)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 20 })
    .backgroundColor('#CC0B1220')
    .justifyContent(FlexAlign.Start)
    .onClick(() => {
      this.closeImagePreview();
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        this.ChatHeader()

        Stack({ alignContent: Alignment.BottomEnd }) {
          Column({ space: 4 }) {
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
                      Text(roleLabel('assistant'))
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
            .onScrollIndex((start: number, end: number) => {
              this.refreshAutoFollowState(end);
            })
            .onReachEnd(() => {
              this.shouldAutoFollowChat = true;
              this.showJumpToLatest = false;
            })
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

              if (this.voicePanelVisible()) {
                this.VoiceComposerTray()
              }

              Row({ space: 6 }) {
                Button() {
                  SymbolGlyph(this.voiceState.micEnabled || this.voiceState.canCancel ? $r('sys.symbol.mic_slash_fill') :
                    $r('sys.symbol.mic_fill'))
                    .fontSize(20)
                    .fontColor([this.voiceMicButtonIconColor()])
                }
                .width(42)
                .height(42)
                .backgroundColor(this.voiceMicButtonBackground())
                .borderRadius(12)
                .border({ width: 1, color: this.voiceMicButtonBorder() })
                .enabled(!this.voiceState.micCooldown)
                .onClick(() => {
                  void this.toggleVoiceMic();
                })

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
                  .onFocus(() => {
                    this.composerFocused = true;
                    this.scrollChatListToEnd(false);
                  })
                  .onBlur(() => {
                    this.composerFocused = false;
                  })
                  .layoutWeight(1)
                  .height(42)
                  .backgroundColor('#F6F7FA')
                  .borderRadius(12)
                  .border({ width: 1, color: '#E5E7EC' })

                Button(this.hasComposerContent() ? $r('app.string.chat_send') : '+')
                  .height(42)
                  .width(58)
                  .fontSize(this.hasComposerContent() ? 12 : 20)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor(this.hasComposerContent() ? (this.canSendChat() ? '#1D5DD8' : '#D6DAE2') : '#FFFFFF')
                  .fontColor(this.hasComposerContent() ? (this.canSendChat() ? '#FFFFFF' : '#99A0AE') : '#4D5563')
                  .borderRadius(12)
                  .border({ width: 1, color: this.hasComposerContent() ? (this.canSendChat() ? '#184DAF' : '#D6DAE2') : '#D6DAE2' })
                  .enabled(this.hasComposerContent() ? this.canSendChat() : true)
                  .onClick(() => {
                    if (this.hasComposerContent()) {
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
          .padding({ left: 12, right: 12, top: 0, bottom: 8 })
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
          .backgroundColor('#F7F8FA')

          if (this.showJumpToLatest) {
            Column() {
              this.JumpToLatestButton()
            }
            .padding({ right: 18, bottom: 94 })
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.End)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')

      if (this.isPreviewVisible()) {
        this.ImagePreviewOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
