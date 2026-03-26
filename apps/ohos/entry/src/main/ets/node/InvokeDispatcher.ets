/**
 * Invoke dispatcher: routes commands to device and system handlers.
 */
import { OpenClawDeviceCommand, OpenClawSystemCommand } from '../protocol/OpenClawProtocol';
import { OpenClawCameraCommand } from '../protocol/OpenClawProtocol';
import { OpenClawLocationCommand } from '../protocol/OpenClawProtocol';
import type { InvokeRequest, InvokeResult, InvokeErrorShape } from '../gateway/GatewaySession';
import { DeviceHandler } from './DeviceHandler';
import { SystemHandler } from './SystemHandler';
import { CameraHandler } from './CameraHandler';
import { LocationHandler } from './LocationHandler';
import type { CanvasInvokeHandler } from '../canvas/CanvasInvokeHandler';

const SUPPORTED_COMMANDS = new Set<string>([
  OpenClawDeviceCommand.Status,
  OpenClawDeviceCommand.Info,
  OpenClawDeviceCommand.Permissions,
  OpenClawDeviceCommand.Health,
  OpenClawSystemCommand.Notify,
  OpenClawCameraCommand.List,
  OpenClawCameraCommand.Snap,
  OpenClawCameraCommand.Clip,
  OpenClawLocationCommand.Get,
]);

function errResult(code: string, message: string): InvokeResult {
  const err: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error: err };
}

export class InvokeDispatcher {
  private deviceHandler: DeviceHandler;
  private systemHandler: SystemHandler;
  private cameraHandler: CameraHandler;
  private locationHandler: LocationHandler;
  private canvasHandler: CanvasInvokeHandler | null;

  constructor(
    deviceHandler: DeviceHandler,
    systemHandler: SystemHandler,
    cameraHandler: CameraHandler,
    locationHandler: LocationHandler,
    canvasHandler: CanvasInvokeHandler | null = null,
  ) {
    this.deviceHandler = deviceHandler;
    this.systemHandler = systemHandler;
    this.cameraHandler = cameraHandler;
    this.locationHandler = locationHandler;
    this.canvasHandler = canvasHandler;
  }

  async handleInvoke(request: InvokeRequest): Promise<InvokeResult> {
    const command = request.command;
    const paramsJson = request.paramsJson;
    if (this.canvasHandler) {
      const canvasRes = await this.canvasHandler.tryHandle(command, paramsJson);
      if (canvasRes !== null) {
        return canvasRes;
      }
    }
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
    if (command === OpenClawCameraCommand.List) {
      return this.cameraHandler.handleList(paramsJson);
    }
    if (command === OpenClawCameraCommand.Snap) {
      return this.cameraHandler.handleSnap(paramsJson);
    }
    if (command === OpenClawCameraCommand.Clip) {
      return this.cameraHandler.handleClip(paramsJson);
    }
    if (command === OpenClawLocationCommand.Get) {
      return this.locationHandler.handleLocationGet(paramsJson);
    }
    return errResult('INVALID_REQUEST', 'INVALID_REQUEST: unknown command');
  }
}
