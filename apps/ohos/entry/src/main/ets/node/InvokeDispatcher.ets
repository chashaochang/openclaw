/**
 * Invoke dispatcher: routes commands to device and system handlers.
 */
import { OpenClawDeviceCommand, OpenClawSystemCommand } from '../protocol/OpenClawProtocol';
import type { InvokeRequest, InvokeResult, InvokeErrorShape } from '../gateway/GatewaySession';
import { DeviceHandler } from './DeviceHandler';
import { SystemHandler } from './SystemHandler';

const SUPPORTED_COMMANDS = new Set<string>([
  OpenClawDeviceCommand.Status,
  OpenClawDeviceCommand.Info,
  OpenClawDeviceCommand.Permissions,
  OpenClawDeviceCommand.Health,
  OpenClawSystemCommand.Notify,
]);

function errResult(code: string, message: string): InvokeResult {
  const err: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error: err };
}

export class InvokeDispatcher {
  private deviceHandler: DeviceHandler;
  private systemHandler: SystemHandler;

  constructor(deviceHandler: DeviceHandler, systemHandler: SystemHandler) {
    this.deviceHandler = deviceHandler;
    this.systemHandler = systemHandler;
  }

  async handleInvoke(request: InvokeRequest): Promise<InvokeResult> {
    const command = request.command;
    const paramsJson = request.paramsJson;
    if (!SUPPORTED_COMMANDS.has(command)) {
      return errResult('INVALID_REQUEST', 'INVALID_REQUEST: unknown command');
    }
    if (command === OpenClawDeviceCommand.Status) {
      return this.deviceHandler.handleDeviceStatus(paramsJson);
    }
    if (command === OpenClawDeviceCommand.Info) {
      return this.deviceHandler.handleDeviceInfo(paramsJson);
    }
    if (command === OpenClawDeviceCommand.Permissions) {
      return this.deviceHandler.handleDevicePermissions(paramsJson);
    }
    if (command === OpenClawDeviceCommand.Health) {
      return this.deviceHandler.handleDeviceHealth(paramsJson);
    }
    if (command === OpenClawSystemCommand.Notify) {
      return this.systemHandler.handleSystemNotify(paramsJson);
    }
    return errResult('INVALID_REQUEST', 'INVALID_REQUEST: unknown command');
  }
}
