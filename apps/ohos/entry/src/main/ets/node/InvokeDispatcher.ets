/**
 * Invoke dispatcher: routes commands to device and system handlers.
 */
import { OpenClawDeviceCommand, OpenClawSystemCommand } from '../protocol/OpenClawProtocol';
import { OpenClawCameraCommand } from '../protocol/OpenClawProtocol';
import { OpenClawCalendarCommand } from '../protocol/OpenClawProtocol';
import { OpenClawContactsCommand } from '../protocol/OpenClawProtocol';
import { OpenClawPhotosCommand } from '../protocol/OpenClawProtocol';
import { OpenClawLocationCommand } from '../protocol/OpenClawProtocol';
import { OpenClawMotionCommand } from '../protocol/OpenClawProtocol';
import { OpenClawNotificationsCommand } from '../protocol/OpenClawProtocol';
import type { InvokeRequest, InvokeResult, InvokeErrorShape } from '../gateway/GatewaySession';
import { DeviceHandler } from './DeviceHandler';
import { SystemHandler } from './SystemHandler';
import { CameraHandler } from './CameraHandler';
import { CalendarHandler } from './CalendarHandler';
import { ContactsHandler } from './ContactsHandler';
import { PhotosHandler } from './PhotosHandler';
import { LocationHandler } from './LocationHandler';
import { MotionHandler } from './MotionHandler';
import { NotificationsHandler } from './NotificationsHandler';
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
  OpenClawCalendarCommand.Events,
  OpenClawCalendarCommand.Add,
  OpenClawContactsCommand.Search,
  OpenClawContactsCommand.Add,
  OpenClawPhotosCommand.Latest,
  OpenClawLocationCommand.Get,
  OpenClawMotionCommand.Activity,
  OpenClawMotionCommand.Pedometer,
  OpenClawNotificationsCommand.List,
  OpenClawNotificationsCommand.Actions,
]);

function errResult(code: string, message: string): InvokeResult {
  const err: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error: err };
}

export class InvokeDispatcher {
  private deviceHandler: DeviceHandler;
  private systemHandler: SystemHandler;
  private cameraHandler: CameraHandler;
  private calendarHandler: CalendarHandler;
  private contactsHandler: ContactsHandler;
  private photosHandler: PhotosHandler;
  private locationHandler: LocationHandler;
  private motionHandler: MotionHandler;
  private notificationsHandler: NotificationsHandler;
  private canvasHandler: CanvasInvokeHandler | null;

  constructor(
    deviceHandler: DeviceHandler,
    systemHandler: SystemHandler,
    cameraHandler: CameraHandler,
    calendarHandler: CalendarHandler,
    contactsHandler: ContactsHandler,
    photosHandler: PhotosHandler,
    locationHandler: LocationHandler,
    motionHandler: MotionHandler,
    notificationsHandler: NotificationsHandler,
    canvasHandler: CanvasInvokeHandler | null = null,
  ) {
    this.deviceHandler = deviceHandler;
    this.systemHandler = systemHandler;
    this.cameraHandler = cameraHandler;
    this.calendarHandler = calendarHandler;
    this.contactsHandler = contactsHandler;
    this.photosHandler = photosHandler;
    this.locationHandler = locationHandler;
    this.motionHandler = motionHandler;
    this.notificationsHandler = notificationsHandler;
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
    if (command === OpenClawCalendarCommand.Events) {
      return this.calendarHandler.handleCalendarEvents(paramsJson);
    }
    if (command === OpenClawCalendarCommand.Add) {
      return this.calendarHandler.handleCalendarAdd(paramsJson);
    }
    if (command === OpenClawContactsCommand.Search) {
      return this.contactsHandler.handleContactsSearch(paramsJson);
    }
    if (command === OpenClawContactsCommand.Add) {
      return this.contactsHandler.handleContactsAdd(paramsJson);
    }
    if (command === OpenClawPhotosCommand.Latest) {
      return this.photosHandler.handlePhotosLatest(paramsJson);
    }
    if (command === OpenClawLocationCommand.Get) {
      return this.locationHandler.handleLocationGet(paramsJson);
    }
    if (command === OpenClawMotionCommand.Activity) {
      return this.motionHandler.handleMotionActivity(paramsJson);
    }
    if (command === OpenClawMotionCommand.Pedometer) {
      return this.motionHandler.handleMotionPedometer(paramsJson);
    }
    if (command === OpenClawNotificationsCommand.List) {
      return this.notificationsHandler.handleNotificationsList(paramsJson);
    }
    if (command === OpenClawNotificationsCommand.Actions) {
      return this.notificationsHandler.handleNotificationsActions(paramsJson);
    }
    return errResult('INVALID_REQUEST', 'INVALID_REQUEST: unknown command');
  }
}
