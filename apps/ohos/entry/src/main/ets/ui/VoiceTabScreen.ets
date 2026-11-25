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

@Component
export struct VoiceTabScreen {
  @Prop statusText: string = '';
  @StorageLink('nodeRuntime') nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  @State voiceState: VoiceUiState = defaultVoiceUiState();
  @State hasMicPermission: boolean = false;

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

  private auxiliaryStatusText(): string {
    const detail = this.voiceState.statusDetail.trim();
    const activity = this.voiceState.activityLabel.trim();
    if (detail.length === 0 || detail === activity) {
      return '';
    }
    return detail;
  }

  private statusChipBackground(): string {
    if (this.voiceState.micEnabled) {
      return '#E8F5E9';
    }
    if (this.voiceState.isSpeaking) {
      return '#FFF4E5';
    }
    if (this.voiceState.isSending) {
      return '#ECF3FF';
    }
    return '#F6F7FA';
  }

  private statusChipBorder(): string {
    if (this.voiceState.micEnabled) {
      return 'rgba(47, 140, 90, 0.30)';
    }
    if (this.voiceState.isSpeaking) {
      return 'rgba(200, 132, 26, 0.24)';
    }
    if (this.voiceState.isSending) {
      return 'rgba(29, 93, 216, 0.24)';
    }
    return '#E5E7EC';
  }

  private statusChipTextColor(): string {
    if (this.voiceState.micEnabled) {
      return '#2F8C5A';
    }
    if (this.voiceState.isSpeaking) {
      return '#C8841A';
    }
    if (this.voiceState.isSending) {
      return '#1D5DD8';
    }
    return '#4D5563';
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
  }

  onPageShow(): void {
    this.refreshMicPermission();
    // Mic tab can be visible without a tab bar click (e.g. restored UI); keep coordinator in sync.
    this.nodeRuntime.setVoiceScreenActive(true);
  }

  aboutToDisappear(): void {
    this.nodeRuntime.setVoiceUiListener(null);
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

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          if (this.voiceState.conversation.length === 0 && !this.voiceState.isSending) {
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

          ForEach(this.voiceState.conversation, (entry: VoiceConversationEntry) => {
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
          }, (entry: VoiceConversationEntry): string => entry.id)

          if (this.voiceState.isSending &&
            !this.voiceState.conversation.some((e: VoiceConversationEntry): boolean =>
              e.role === VoiceConversationRole.Assistant && e.isStreaming)) {
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

          if (this.voiceState.liveTranscript.trim().length > 0) {
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
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .padding({ left: 20, right: 20, bottom: 12 })
      }
      .layoutWeight(1)
      .width('100%')
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
          Button() {
            SymbolGlyph(this.voiceState.micEnabled || this.voiceState.canCancel ? $r('sys.symbol.mic_slash_fill') :
              $r('sys.symbol.mic_fill'))
              .fontSize(26)
              .fontColor([Color.White])
          }
          .width(60)
          .height(60)
          .borderRadius(30)
          .backgroundColor(this.voiceState.micCooldown ?
            '#8A92A2' :
            (this.voiceState.isSpeaking ? '#C8841A' : (this.voiceState.micEnabled ? '#dc3545' :
              (this.voiceState.canCancel ? '#dc3545' : '#1D5DD8'))))
          .enabled(!this.voiceState.micCooldown)
          .onClick(() => {
            if (this.voiceState.micCooldown) {
              return;
            }
            this.refreshMicPermission();
            this.nodeRuntime.setVoiceScreenActive(true);
            if (this.voiceState.micEnabled) {
              void this.nodeRuntime.setVoiceMicEnabled(false);
            } else if (this.voiceState.isSpeaking) {
              if (this.hasMicPermission) {
                void this.nodeRuntime.setVoiceMicEnabled(true);
              } else {
                void this.requestMicAndEnable();
              }
            } else if (this.voiceState.canCancel) {
              void this.nodeRuntime.cancelVoicePendingTurn();
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

      Row() {
        Text(this.chipsLine())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusChipTextColor())
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor(this.statusChipBackground())
          .borderRadius(999)
          .border({
            width: 1,
            color: this.statusChipBorder(),
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 20, right: 20, bottom: 10 })

      if (this.auxiliaryStatusText().length > 0) {
        Text(this.auxiliaryStatusText())
          .fontSize(12)
          .fontColor('#8A92A2')
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

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
