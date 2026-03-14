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
}
