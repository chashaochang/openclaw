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
  readonly Camera: string;
  readonly Location: string;
  readonly Notifications: string;
  readonly Device: string;
  readonly System: string;
}

export const OpenClawCapability: OpenClawCapabilityType = {
  Canvas: 'canvas',
  Camera: 'camera',
  Location: 'location',
  Notifications: 'notifications',
  Device: 'device',
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
