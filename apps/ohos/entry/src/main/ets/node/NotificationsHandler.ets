/**
 * Notifications invoke handler: lists subscribed notifications and exposes unsupported actions clearly.
 */
import { common } from '@kit.AbilityKit';
import { notificationExtensionSubscription } from '@kit.NotificationKit';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';
import { NotificationStore, type StoredNotificationEntry } from './NotificationStore';

interface NotificationsListPayload {
  enabled: boolean;
  connected: boolean;
  count: number;
  notifications: StoredNotificationEntry[];
}

type JsonValue = object | string | number | boolean | null | undefined;

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

export class NotificationsHandler {
  private context: common.UIAbilityContext;
  private store: NotificationStore;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.store = new NotificationStore(context);
  }

  async handleNotificationsList(_paramsJson: string | null): Promise<InvokeResult> {
    const enabled = await this.readNotificationSubscriptionEnabled();
    const snapshot = await this.store.readSnapshot();
    const payload: NotificationsListPayload = {
      enabled,
      connected: enabled,
      count: snapshot.notifications.length,
      notifications: snapshot.notifications,
    };
    return invokeOk(JSON.stringify(payload));
  }

  async handleNotificationsActions(paramsJson: string | null): Promise<InvokeResult> {
    const enabled = await this.readNotificationSubscriptionEnabled();
    if (!enabled) {
      return invokeErr(
        'NOTIFICATIONS_DISABLED',
        'NOTIFICATIONS_DISABLED: enable notification subscription in Settings',
      );
    }
    const params = this.parseParamsObject(paramsJson);
    if (!params) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }
    const key = this.readString(params, 'key');
    if (!key) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: key required');
    }
    const action = this.readString(params, 'action');
    if (!action) {
      return invokeErr(
        'INVALID_REQUEST',
        'INVALID_REQUEST: action required (open|dismiss|reply)',
      );
    }
    return invokeErr(
      'ACTION_UNAVAILABLE',
      `ACTION_UNAVAILABLE: notifications.${action.toLowerCase()} is not supported on HarmonyOS`,
    );
  }

  private parseParamsObject(paramsJson: string | null): Record<string, JsonValue> | null {
    if (!paramsJson || paramsJson.trim().length === 0) {
      return null;
    }
    try {
      return JSON.parse(paramsJson) as Record<string, JsonValue>;
    } catch {
      return null;
    }
  }

  private readString(root: Record<string, JsonValue>, key: string): string | null {
    const value = root[key];
    if (typeof value !== 'string') {
      return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }

  private async readNotificationSubscriptionEnabled(): Promise<boolean> {
    try {
      return await notificationExtensionSubscription.isUserGranted();
    } catch {
      return false;
    }
  }
}
