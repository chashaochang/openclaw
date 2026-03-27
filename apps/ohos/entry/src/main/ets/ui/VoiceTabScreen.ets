/**
 * Voice tab: CoreSpeechKit STT, chat.send, assistant bubbles + TTS (Android parity).
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { NodeRuntime } from '../NodeRuntime';
import type { VoiceConversationEntry, VoiceUiState } from '../voice/VoiceModels';
import { VoiceConversationRole } from '../voice/VoiceModels';

function defaultVoiceUiState(): VoiceUiState {
  const s: VoiceUiState = {
    micEnabled: false,
    micCooldown: false,
    speakerEnabled: true,
    liveTranscript: '',
    queuedMessages: [],
    conversation: [],
    isSending: false,
    activityLabel: 'Mic off',
  };
  return s;
}

@Component
export struct VoiceTabScreen {
  @Prop statusText: string = '';
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State voiceState: VoiceUiState = defaultVoiceUiState();
  @State hasMicPermission: boolean = false;
  @State micPulseLevel: number = 0.08;
  private voiceListScroller: ListScroller = new ListScroller();
  private voicePulseTimer: number = -1;
  private prevVoiceScrollKey: string = '';
  private lastMicEnabled: boolean = false;

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

  private chipsLine(): string {
    const g = this.statusText.trim().length > 0 ? this.statusText.trim() : 'Offline';
    return `${g} · ${this.voiceState.activityLabel}`;
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

  aboutToAppear(): void {
    this.refreshMicPermission();
    this.nodeRuntime.setVoiceUiListener((s: VoiceUiState) => {
      this.voiceState = s;
    });
    this.syncMicPulseState(this.voiceState.micEnabled);
  }

  onPageShow(): void {
    this.refreshMicPermission();
    // Mic tab can be visible without a tab bar click (e.g. restored UI); keep coordinator in sync.
    this.nodeRuntime.setVoiceScreenActive(true);
  }

  aboutToDisappear(): void {
    this.nodeRuntime.setVoiceUiListener(null);
    this.stopMicPulse();
  }

  aboutToUpdate(): void {
    this.syncMicPulseState(this.voiceState.micEnabled);
    const scrollKey = this.voiceScrollKey();
    if (scrollKey !== this.prevVoiceScrollKey) {
      this.prevVoiceScrollKey = scrollKey;
      this.scheduleVoiceScrollToEnd();
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

  private hasStreamingAssistantEntry(): boolean {
    for (let i = 0; i < this.voiceState.conversation.length; i++) {
      const entry = this.voiceState.conversation[i];
      if (entry.role === VoiceConversationRole.Assistant && entry.isStreaming) {
        return true;
      }
    }
    return false;
  }

  private voiceListItemCount(): number {
    let count = this.voiceState.conversation.length;
    if (count === 0 && !this.voiceState.isSending) {
      count += 1;
    }
    if (this.voiceState.isSending && !this.hasStreamingAssistantEntry()) {
      count += 1;
    }
    if (this.voiceState.liveTranscript.trim().length > 0) {
      count += 1;
    }
    return count;
  }

  private voiceListLastIndex(): number {
    const count = this.voiceListItemCount();
    return count > 0 ? count - 1 : 0;
  }

  private voiceScrollKey(): string {
    const conversation = this.voiceState.conversation;
    const last = conversation.length > 0 ? conversation[conversation.length - 1] : null;
    const lastId = last ? last.id : '-';
    const lastTextLen = last ? last.text.length : 0;
    const lastStreaming = last && last.isStreaming ? '1' : '0';
    const transcriptLen = this.voiceState.liveTranscript.trim().length;
    return `${conversation.length}-${lastId}-${lastTextLen}-${lastStreaming}-${transcriptLen}-${this.voiceState.isSending ? 1 : 0}`;
  }

  private scheduleVoiceScrollToEnd(): void {
    const delays: number[] = [0, 80, 180];
    for (let i = 0; i < delays.length; i++) {
      setTimeout(() => {
        this.scrollVoiceListToEnd(i > 0);
      }, delays[i]);
    }
  }

  private scrollVoiceListToEnd(animate: boolean): void {
    const lastIndex = this.voiceListLastIndex();
    if (lastIndex < 0) {
      return;
    }
    try {
      this.voiceListScroller.scrollToIndex(lastIndex, animate, ScrollAlign.END);
    } catch {
      // List may not be attached yet.
    }
  }

  private syncMicPulseState(enabled: boolean): void {
    if (enabled === this.lastMicEnabled) {
      return;
    }
    this.lastMicEnabled = enabled;
    if (enabled) {
      this.startMicPulse();
      return;
    }
    this.stopMicPulse();
  }

  private startMicPulse(): void {
    this.stopMicPulse();
    const levels: number[] = [0.10, 0.22, 0.38, 0.58, 0.42, 0.26];
    let idx = 0;
    this.micPulseLevel = levels[0];
    this.voicePulseTimer = setInterval(() => {
      idx = (idx + 1) % levels.length;
      this.micPulseLevel = levels[idx];
    }, 180) as number;
  }

  private stopMicPulse(): void {
    if (this.voicePulseTimer >= 0) {
      clearInterval(this.voicePulseTimer);
      this.voicePulseTimer = -1;
    }
    this.micPulseLevel = 0.08;
  }

  build() {
    Column() {
      List({ scroller: this.voiceListScroller, initialIndex: this.voiceListLastIndex(), space: 10 }) {
        if (this.voiceState.conversation.length === 0 && !this.voiceState.isSending) {
          ListItem() {
            Column({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.mic_fill'))
                .fontSize(48)
                .fontColor(['#8A92A2'])
              Text($r('app.string.voice_hint_tap_mic'))
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5563')
              Text($r('app.string.voice_hint_mic_stop_send'))
                .fontSize(14)
                .fontColor('#8A92A2')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: 32, bottom: 16 })
            .alignItems(HorizontalAlign.Center)
          }
        }

        ForEach(this.voiceState.conversation, (entry: VoiceConversationEntry) => {
          ListItem() {
            Row() {
              if (entry.role === VoiceConversationRole.User) {
                Blank().layoutWeight(0.08)
              }
              Column({ space: 4 }) {
                Text(entry.role === VoiceConversationRole.User ?
                  this.resStr($r('app.string.voice_bubble_you')) : this.resStr($r('app.string.voice_bubble_assistant')))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(entry.role === VoiceConversationRole.User ? '#1D5DD8' : '#8A92A2')
                Text(entry.isStreaming && entry.text.trim().length === 0 ?
                  this.resStr($r('app.string.voice_listening_response')) :
                  entry.text)
                  .fontSize(15)
                  .fontColor('#17181C')
                  .width('100%')
              }
              .width('90%')
              .alignItems(HorizontalAlign.Start)
              .padding(12)
              .backgroundColor(entry.role === VoiceConversationRole.User ? '#ECF3FF' : '#FFFFFF')
              .borderRadius(12)
              .border({
                width: 1,
                color: entry.role === VoiceConversationRole.User ? 'rgba(29, 93, 216, 0.22)' : '#E5E7EC',
              })
              if (entry.role !== VoiceConversationRole.User) {
                Blank().layoutWeight(0.08)
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
        }, (entry: VoiceConversationEntry): string => entry.id)

        if (this.voiceState.isSending && !this.hasStreamingAssistantEntry()) {
          ListItem() {
            Row() {
              Column({ space: 4 }) {
                Text($r('app.string.voice_bubble_assistant'))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#8A92A2')
                Text('…')
                  .fontSize(15)
                  .fontColor('#8A92A2')
              }
              .width('68%')
              .alignItems(HorizontalAlign.Start)
              .padding(12)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: '#E5E7EC' })
              Blank().layoutWeight(0.32)
            }
            .width('100%')
          }
        }

        if (this.voiceState.liveTranscript.trim().length > 0) {
          ListItem() {
            Text(this.voiceState.liveTranscript.trim())
              .fontSize(14)
              .fontColor('#17181C')
              .width('100%')
              .padding(12)
              .backgroundColor('#ECF3FF')
              .borderRadius(14)
              .border({ width: 1, color: 'rgba(29, 93, 216, 0.2)' })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 20, right: 20, bottom: 12 })
      .divider({ strokeWidth: 0 })
      .scrollBar(BarState.Off)

      Row() {
        Column({ space: 4 }) {
          Button() {
            SymbolGlyph(this.voiceState.speakerEnabled ? $r('sys.symbol.speaker_fill') :
              $r('sys.symbol.speaker_slash_fill'))
              .fontSize(22)
              .fontColor([Color.White])
          }
          .width(48)
          .height(48)
          .borderRadius(24)
          .backgroundColor(this.voiceState.speakerEnabled ? '#E8F0FE' : '#FFEBEE')
          .onClick(() => {
            void this.nodeRuntime.setVoiceSpeakerEnabled(!this.voiceState.speakerEnabled);
          })
          Text(this.voiceState.speakerEnabled ? $r('app.string.voice_speaker_on') : $r('app.string.voice_speaker_muted'))
            .fontSize(11)
            .fontColor(this.voiceState.speakerEnabled ? '#8A92A2' : '#dc3545')
        }

        Column() {
          if (this.voiceState.micEnabled) {
            Row()
              .width(72 + this.micPulseLevel * 22)
              .height(72 + this.micPulseLevel * 22)
              .borderRadius(999)
              .backgroundColor(`rgba(220, 53, 69, ${0.12 + this.micPulseLevel * 0.14})`)
          }
          Button() {
            SymbolGlyph($r('sys.symbol.mic_fill'))
              .fontSize(26)
              .fontColor([Color.White])
          }
          .width(60)
          .height(60)
          .borderRadius(30)
          .backgroundColor(this.voiceState.micCooldown ?
            '#8A92A2' :
            (this.voiceState.micEnabled ? '#dc3545' : '#1D5DD8'))
          .enabled(!this.voiceState.micCooldown)
          .onClick(() => {
            if (this.voiceState.micCooldown) {
              return;
            }
            if (this.voiceState.micEnabled) {
              void this.nodeRuntime.setVoiceMicEnabled(false);
            } else {
              if (this.hasMicPermission) {
                void this.nodeRuntime.setVoiceMicEnabled(true);
              } else {
                void this.requestMicAndEnable();
              }
            }
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Column({ space: 4 }) {
          Row().width(48).height(48)
          Text('')
            .fontSize(11)
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })
      .justifyContent(FlexAlign.SpaceBetween)

      Text(this.chipsLine())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#4D5563')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .width('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(this.voiceState.micEnabled ? '#E8F5E9' : '#F6F7FA')
        .borderRadius(999)
        .border({
          width: 1,
          color: this.voiceState.micEnabled ? 'rgba(47, 140, 90, 0.3)' : '#E5E7EC',
        })
        .margin({ left: 20, right: 20, bottom: 10 })

      if (!this.hasMicPermission) {
        Column({ space: 8 }) {
          Text($r('app.string.voice_mic_permission_rationale'))
            .fontSize(13)
            .fontColor('#C8841A')
            .textAlign(TextAlign.Center)
            .width('100%')
          Button(this.resStr($r('app.string.voice_open_settings')))
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor('#4D5563')
            .borderRadius(12)
            .width('100%')
            .onClick(() => {
              this.openAppSettings();
            })
        }
        .padding({ left: 20, right: 20, bottom: 16 })
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#F7F8FA')
  }
}
