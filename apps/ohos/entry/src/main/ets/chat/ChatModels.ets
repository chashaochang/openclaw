/**
 * Chat message models.
 */
export interface ChatMessageContent {
  type: string;
  text?: string;
  mimeType?: string;
  fileName?: string;
  base64?: string;
}

export interface ChatMessage {
  id: string;
  role: string;
  content: ChatMessageContent[];
  timestampMs?: number;
}

export interface ChatSessionEntry {
  key: string;
  updatedAtMs?: number;
  displayName?: string;
  derivedTitle?: string;
  lastMessagePreview?: string;
}

/** Local image queued in the composer before send (Android PendingImageAttachment). */
export interface ChatPendingAttachment {
  id: string;
  fileName: string;
  mimeType: string;
  base64: string;
}

/** In-flight tool call from gateway agent stream (Android ChatPendingToolCall). */
export interface ChatPendingToolCall {
  toolCallId: string;
  name: string;
  /** Raw args object from gateway; UI may show name only. */
  args: Record<string, object | string | number | boolean | null> | null;
  startedAtMs: number;
  isError: boolean | null;
}
