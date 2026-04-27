/**
 * OpenClaw Gateway protocol constants (matches Android OpenClawProtocolConstants).
 */
export const GATEWAY_PROTOCOL_VERSION = 3;

export interface OpenClawDeviceCommandType {
  Status: string;
  Info: string;
  Permissions: string;
  Health: string;
}

export const OpenClawDeviceCommand: OpenClawDeviceCommandType = {
  Status: 'device.status',
  Info: 'device.info',
  Permissions: 'device.permissions',
  Health: 'device.health',
};

export interface OpenClawSystemCommandType {
  Notify: string;
}

export const OpenClawSystemCommand: OpenClawSystemCommandType = {
  Notify: 'system.notify',
};

export interface OpenClawLocationCommandType {
  Get: string;
}

export const OpenClawLocationCommand: OpenClawLocationCommandType = {
  Get: 'location.get',
};

export interface OpenClawCalendarCommandType {
  Events: string;
  Add: string;
}

export const OpenClawCalendarCommand: OpenClawCalendarCommandType = {
  Events: 'calendar.events',
  Add: 'calendar.add',
};

export interface OpenClawContactsCommandType {
  Search: string;
  Add: string;
}

export const OpenClawContactsCommand: OpenClawContactsCommandType = {
  Search: 'contacts.search',
  Add: 'contacts.add',
};

export interface OpenClawPhotosCommandType {
  Latest: string;
}

export const OpenClawPhotosCommand: OpenClawPhotosCommandType = {
  Latest: 'photos.latest',
};

export interface OpenClawMotionCommandType {
  Activity: string;
  Pedometer: string;
}

export const OpenClawMotionCommand: OpenClawMotionCommandType = {
  Activity: 'motion.activity',
  Pedometer: 'motion.pedometer',
};

export interface OpenClawCameraCommandType {
  List: string;
  Snap: string;
  Clip: string;
}

export const OpenClawCameraCommand: OpenClawCameraCommandType = {
  List: 'camera.list',
  Snap: 'camera.snap',
  Clip: 'camera.clip',
};

export interface OpenClawNotificationsCommandType {
  List: string;
  Actions: string;
}

export const OpenClawNotificationsCommand: OpenClawNotificationsCommandType = {
  List: 'notifications.list',
  Actions: 'notifications.actions',
};

export interface OpenClawCapabilityType {
  readonly Canvas: string;
  readonly Calendar: string;
  readonly Camera: string;
  readonly Contacts: string;
  readonly Location: string;
  readonly Motion: string;
  readonly Notifications: string;
  readonly VoiceWake: string;
  readonly Device: string;
  readonly Photos: string;
  readonly System: string;
}

export const OpenClawCapability: OpenClawCapabilityType = {
  Canvas: 'canvas',
  Calendar: 'calendar',
  Camera: 'camera',
  Contacts: 'contacts',
  Location: 'location',
  Motion: 'motion',
  Notifications: 'notifications',
  VoiceWake: 'voiceWake',
  Device: 'device',
  Photos: 'photos',
  System: 'system',
};

export interface OpenClawCanvasCommandType {
  Present: string;
  Hide: string;
  Navigate: string;
  Eval: string;
  Snapshot: string;
}

export const OpenClawCanvasCommand: OpenClawCanvasCommandType = {
  Present: 'canvas.present',
  Hide: 'canvas.hide',
  Navigate: 'canvas.navigate',
  Eval: 'canvas.eval',
  Snapshot: 'canvas.snapshot',
};

export interface OpenClawCanvasA2UICommandType {
  Push: string;
  PushJSONL: string;
  Reset: string;
}

export const OpenClawCanvasA2UICommand: OpenClawCanvasA2UICommandType = {
  Push: 'canvas.a2ui.push',
  PushJSONL: 'canvas.a2ui.pushJSONL',
  Reset: 'canvas.a2ui.reset',
};
