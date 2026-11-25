/**
 * Voice tab transcript model (matches Android VoiceConversationEntry).
 */

export enum VoiceConversationRole {
  User = 'user',
  Assistant = 'assistant',
}

export interface VoiceConversationEntry {
  id: string;
  role: VoiceConversationRole;
  text: string;
  isStreaming: boolean;
}

export interface VoiceUiState {
  micEnabled: boolean;
  micCooldown: boolean;
  isSpeaking: boolean;
  speakerEnabled: boolean;
  talkModeEnabled: boolean;
  canCancel: boolean;
  liveTranscript: string;
  queuedMessages: string[];
  conversation: VoiceConversationEntry[];
  isSending: boolean;
  /** Second line after gateway status, e.g. "Listening" / "Mic off" / "2 queued" */
  activityLabel: string;
  /** Full voice status or error detail for auxiliary UI messaging. */
  statusDetail: string;
}
