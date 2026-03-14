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

export interface OpenClawCapabilityType {
  readonly Device: string;
  readonly System: string;
}

export const OpenClawCapability: OpenClawCapabilityType = {
  Device: 'device',
  System: 'system',
};
