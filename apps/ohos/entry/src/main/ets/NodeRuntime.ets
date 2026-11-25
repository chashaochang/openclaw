/**
 * Node runtime: gateway, chat, invoke. Central app state.
 */
import { abilityAccessCtrl, common, Permissions } from "@kit.AbilityKit";
import { window } from "@kit.ArkUI";
import { deviceInfo } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  OpenClawCapability,
  OpenClawCalendarCommand,
  OpenClawCameraCommand,
  OpenClawCanvasA2UICommand,
  OpenClawCanvasCommand,
  OpenClawContactsCommand,
  OpenClawDeviceCommand,
  OpenClawLocationCommand,
  OpenClawMotionCommand,
  OpenClawNotificationsCommand,
  OpenClawPhotosCommand,
  OpenClawSystemCommand,
} from "./protocol/OpenClawProtocol";
import { SecurePrefs } from "./common/SecurePrefs";
import {
  allowsNotificationPackage,
  isWithinQuietHours,
  normalizeLocalHourMinute,
  notificationPackageFilterModeFromRaw,
  NotificationPackageFilterMode,
  type NotificationForwardingPolicy,
} from "./common/NotificationForwardingPolicy";
import { DeviceIdentityStore } from "./gateway/DeviceIdentityStore";
import { DeviceAuthStore } from "./gateway/DeviceAuthStore";
import { GatewaySession, GatewayConnectOptions, GatewayClientInfo } from "./gateway/GatewaySession";
import { GatewayEndpoint } from "./gateway/GatewayEndpoint";
import {
  clearStoredFingerprint,
  clearTrustedCertPath,
  getTrustedCertPath,
  getStoredFingerprint,
  hasTrustedCertPath,
  probeGatewayTlsCertificate,
  storeFingerprint,
  writeTrustedCertPem,
} from "./gateway/GatewayTls";
import { ChatController } from "./chat/ChatController";
import { DeviceHandler } from "./node/DeviceHandler";
import { SystemHandler } from "./node/SystemHandler";
import { InvokeDispatcher } from "./node/InvokeDispatcher";
import { CameraHandler } from "./node/CameraHandler";
import { CalendarHandler } from "./node/CalendarHandler";
import { ContactsHandler } from "./node/ContactsHandler";
import { PhotosHandler } from "./node/PhotosHandler";
import { LocationHandler } from "./node/LocationHandler";
import { MotionHandler } from "./node/MotionHandler";
import { NotificationStore, type StoredNotificationEntry } from "./node/NotificationStore";
import { NotificationsHandler } from "./node/NotificationsHandler";
import { CanvasWebHost, OpenClawCanvasA2UIBridge } from "./canvas/CanvasWebHost";
import { CanvasInvokeHandler } from "./canvas/CanvasInvokeHandler";
import { isTrustedCanvasActionUrl } from "./canvas/CanvasActionTrust";
import {
  extractActionName,
  formatAgentMessage,
  jsDispatchA2UIActionStatus,
  type A2UIUserActionMap,
} from "./canvas/OpenClawCanvasA2UIAction";
import { VoiceCoordinator, type VoiceStateListener } from "./voice/VoiceCoordinator";
import { VoiceWakeManager } from "./voice/VoiceWakeManager";
import { VoiceWakeMode, voiceWakeModeFromRaw } from "./voice/VoiceWakeMode";
import { defaultWakeWords, parseWakeWordsCsv, sanitizeWakeWords } from "./voice/WakeWords";
import { LocationMode, locationModeFromRaw } from "./LocationMode";

const CLIENT_ID = "openclaw-android";
const VERSION = "1.0.0";
const LOG_DOMAIN = 0x0000;
const CANVAS_LOG_TAG = 'CanvasScreen';

interface HomeCanvasPayloadShape {
  gatewayState: string;
  eyebrow: string;
  title: string;
  subtitle: string;
  gatewayLabel: string;
  activeAgentName: string;
  activeAgentBadge: string;
  activeAgentCaption: string;
  agentCount: number;
  agents: object[];
  footer: string;
}

interface HomeCanvasAgentCardShape {
  id: string;
  name: string;
  badge: string;
  caption: string;
  isActive: boolean;
}

interface GatewayAgentSummaryShape {
  id: string;
  name: string | null;
  emoji: string | null;
}

interface NodePermissionsShape {
  camera: boolean;
  location: boolean;
  microphone: boolean;
}

interface VoiceWakeTriggersPayloadShape {
  triggers?: string[];
}

interface NotificationChangedPayloadShape {
  change: string;
  key: string;
  packageName: string;
  postTimeMs: number;
  isOngoing: boolean;
  isClearable: boolean;
  sessionKey?: string;
  title?: string;
  text?: string;
  subText?: string;
  category?: string;
  channelId?: string;
}

export interface NotificationForwardingCandidateApp {
  packageName: string;
  label: string;
}

interface CanvasRehydrateRequestPayloadShape {
  message: string;
  sessionKey: string;
  thinking: string;
  deliver: boolean;
}

export type StatusListener = (status: NodeStatus) => void;

export interface NodeStatus {
  statusText: string;
  isConnected: boolean;
  remoteAddress: string;
}

export type CameraHudKind = "photo" | "recording" | "success" | "error";

export interface CameraHudState {
  token: number;
  kind: CameraHudKind;
  message: string;
}

export interface CanvasUiState {
  a2uiHydrated: boolean;
  rehydratePending: boolean;
  rehydrateErrorText: string | null;
  pageLoading: boolean;
  pageErrorText: string | null;
  pageErrorDetail: string | null;
  targetUrl: string | null;
  currentUrl: string | null;
  isDefaultScaffold: boolean;
}

export interface GatewayTrustPrompt {
  stableId: string;
  host: string;
  port: number;
  useTls: boolean;
  fingerprintSha256: string;
  certPem: string;
}

export class NodeRuntime {
  private static readonly CAMERA_ENABLED_KEY = "camera.enabled";
  private static readonly LOCATION_MODE_KEY = "location.enabledMode";
  private static readonly LOCATION_PRECISE_ENABLED_KEY = "location.preciseEnabled";
  private static readonly PREVENT_SLEEP_KEY = "screen.preventSleep";
  private static readonly NOTIFICATION_FORWARDING_ENABLED_KEY = "notifications.forwarding.enabled";
  private static readonly NOTIFICATION_FORWARDING_MODE_KEY = "notifications.forwarding.mode";
  private static readonly NOTIFICATION_FORWARDING_PACKAGES_KEY = "notifications.forwarding.packages";
  private static readonly NOTIFICATION_FORWARDING_QUIET_HOURS_ENABLED_KEY = "notifications.forwarding.quietHours.enabled";
  private static readonly NOTIFICATION_FORWARDING_QUIET_START_KEY = "notifications.forwarding.quietHours.start";
  private static readonly NOTIFICATION_FORWARDING_QUIET_END_KEY = "notifications.forwarding.quietHours.end";
  private static readonly NOTIFICATION_FORWARDING_MAX_EVENTS_KEY = "notifications.forwarding.maxEventsPerMinute";
  private static readonly NOTIFICATION_FORWARDING_SESSION_KEY = "notifications.forwarding.sessionKey";
  private static readonly NOTIFICATION_FORWARDING_DEFAULT_QUIET_START = "22:00";
  private static readonly NOTIFICATION_FORWARDING_DEFAULT_QUIET_END = "07:00";
  private static readonly NOTIFICATION_FORWARDING_DEFAULT_BLOCKED_PACKAGE = "cn.xiaobai.clawapp";
  private static readonly VOICE_WAKE_MODE_KEY = "voiceWake.mode";
  private static readonly VOICE_WAKE_TRIGGER_WORDS_KEY = "voiceWake.triggerWords";
  private context: common.UIAbilityContext;
  private prefs: SecurePrefs;
  private identityStore: DeviceIdentityStore;
  private deviceAuthStore: DeviceAuthStore;
  private operatorSession: GatewaySession | null = null;
  private nodeSession: GatewaySession | null = null;
  private chatController: ChatController | null = null;
  private statusListener: StatusListener | null = null;
  private _statusText = "Offline";
  private _isConnected = false;
  private _remoteAddress = "";
  private gatewayServerName: string | null = null;
  private gatewayMainSessionKey: string | null = null;
  private gatewayDefaultAgentId: string | null = null;
  private gatewayAgents: GatewayAgentSummaryShape[] = [];
  private operatorConnected = false;
  private nodeConnected = false;
  private operatorStatusText = "Offline";
  private nodeStatusText = "Offline";
  private _onboardingCompleted = false;
  private _cameraEnabled = true;
  private _locationMode: LocationMode = LocationMode.Off;
  private _locationPreciseEnabled = true;
  private _preventSleep = true;
  private _voiceWakeMode: VoiceWakeMode = VoiceWakeMode.Foreground;
  private canvasDebugEnabled = false;
  private _onboardingListener: ((completed: boolean) => void) | null = null;
  private foregroundActive = true;
  private mainWindow: window.Window | null = null;
  private notificationStore: NotificationStore;
  private notificationForwardPollTimer: number | null = null;
  private notificationForwardingBaselineReady = false;
  private notificationSnapshotByKey = new Map<string, StoredNotificationEntry>();
  private notificationForwardingTimestamps: number[] = [];
  private voiceWakeSyncPromise: Promise<void> = Promise.resolve();
  private canvasWebHost: CanvasWebHost = new CanvasWebHost();
  private a2uiBridge: OpenClawCanvasA2UIBridge;
  private voiceCoordinator: VoiceCoordinator;
  private voiceWakeManager: VoiceWakeManager;
  private canvasA2uiHydrated = false;
  private canvasRehydratePending = false;
  private canvasRehydrateErrorText: string | null = null;
  private canvasPageLoading = false;
  private canvasPageErrorText: string | null = null;
  private canvasPageErrorDetail: string | null = null;
  private didAutoRequestCanvasRehydrate = false;
  private canvasRehydrateSeq = 0;
  private canvasUiListener: ((state: CanvasUiState) => void) | null = null;
  private cameraHudSeq = 0;
  private cameraHudTimer: number = -1;
  private cameraHud: CameraHudState | null = null;
  private cameraHudListener: ((state: CameraHudState | null) => void) | null = null;
  private cameraFlashToken = 0;
  private cameraFlashListener: ((token: number) => void) | null = null;
  private pendingGatewayTrust: GatewayTrustPrompt | null = null;
  private gatewayTrustListener: ((prompt: GatewayTrustPrompt | null) => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.prefs = new SecurePrefs(context);
    this.identityStore = new DeviceIdentityStore(context);
    this.deviceAuthStore = new DeviceAuthStore(this.prefs);
    this.notificationStore = new NotificationStore(context);
    this.voiceCoordinator = new VoiceCoordinator(this.prefs, () => this.chatController, () => this._isConnected);
    this.voiceCoordinator.setActivityListener(() => {
      void this.syncVoiceWakeState();
    });
    this.voiceWakeManager = new VoiceWakeManager(async (command: string) => {
      await this.voiceCoordinator.speakWakeCommand(command);
    });
    this.a2uiBridge = new OpenClawCanvasA2UIBridge((payload: string) => {
      void this.handleCanvasA2UIActionFromWebView(payload);
    });
    this.prefs.getBoolean("onboarding.completed").then((v) => {
      this._onboardingCompleted = v;
      this._onboardingListener?.(v);
    });
    void this.hydrateFeaturePrefs();
    this.startNotificationForwardingLoop();
  }

  private async hydrateFeaturePrefs(): Promise<void> {
    await Promise.all([
      this.getCameraEnabled(),
      this.getLocationMode(),
      this.getLocationPreciseEnabled(),
      this.getPreventSleep(),
      this.getCanvasDebugEnabled(),
      this.getVoiceWakeMode(),
      this.getVoiceWakeWords(),
    ]);
  }

  private effectiveVoiceWakeMode(mode: VoiceWakeMode): VoiceWakeMode {
    return mode === VoiceWakeMode.Always ? VoiceWakeMode.Foreground : mode;
  }

  private buildGatewayStableId(host: string, port: number, useTls: boolean): string {
    return `manual-${host.trim()}-${port}-${useTls}`;
  }

  private parseVoiceWakePayload(payloadJson: string | null): string[] | null {
    const trimmed = payloadJson?.trim() ?? "";
    if (trimmed.length === 0) {
      return null;
    }
    try {
      const payload = JSON.parse(trimmed) as VoiceWakeTriggersPayloadShape;
      return sanitizeWakeWords(Array.isArray(payload.triggers) ? payload.triggers : []);
    } catch {
      return null;
    }
  }

  private async refreshVoiceWakeWordsFromGateway(): Promise<void> {
    const session = this.operatorSession;
    if (!session || !this._isConnected) {
      return;
    }
    try {
      const res = await session.request("voicewake.get", null, 10000);
      if (!res.ok) {
        return;
      }
      const triggers = this.parseVoiceWakePayload(res.payloadJson);
      if (!triggers) {
        return;
      }
      await this.applyVoiceWakeWords(triggers, false);
    } catch {
      // best-effort
    }
  }

  private async pushVoiceWakeWordsToGateway(): Promise<void> {
    const session = this.operatorSession;
    if (!session || !this._isConnected) {
      return;
    }
    try {
      const params: Record<string, object | string | number | boolean | null> = {};
      params["triggers"] = await this.getVoiceWakeWords() as object;
      await session.request("voicewake.set", params, 10000);
    } catch {
      // best-effort
    }
  }

  private async applyVoiceWakeWords(words: string[], syncGateway: boolean): Promise<void> {
    const sanitized = sanitizeWakeWords(words, defaultWakeWords());
    await this.prefs.putString(
      NodeRuntime.VOICE_WAKE_TRIGGER_WORDS_KEY,
      JSON.stringify(sanitized),
    );
    this.voiceWakeManager.setTriggerWords(sanitized);
    if (syncGateway) {
      await this.pushVoiceWakeWordsToGateway();
    }
  }

  private syncVoiceWakeState(): Promise<void> {
    this.voiceWakeSyncPromise = this.voiceWakeSyncPromise
      .then(() => this.syncVoiceWakeStateNow())
      .catch(() => this.syncVoiceWakeStateNow());
    return this.voiceWakeSyncPromise;
  }

  private async syncVoiceWakeStateNow(): Promise<void> {
    const mode = this.effectiveVoiceWakeMode(await this.getVoiceWakeMode());
    const hasMicPermission = this.hasAnyPermission(["ohos.permission.MICROPHONE"]);
    if (mode === VoiceWakeMode.Off) {
      await this.voiceWakeManager.stop("Off");
      return;
    }
    if (!hasMicPermission) {
      await this.voiceWakeManager.stop("Microphone permission required");
      return;
    }
    if (!this.foregroundActive) {
      await this.voiceWakeManager.stop("Foreground only");
      return;
    }
    if (!this._isConnected) {
      await this.voiceWakeManager.stop("Gateway offline");
      return;
    }
    if (this.voiceCoordinator.isBusyForVoiceWake()) {
      await this.voiceWakeManager.stop("Voice session active");
      return;
    }
    this.voiceWakeManager.setTriggerWords(await this.getVoiceWakeWords());
    await this.voiceWakeManager.start();
  }

  getCanvasWebHost(): CanvasWebHost {
    return this.canvasWebHost;
  }

  getCanvasA2UIBridge(): OpenClawCanvasA2UIBridge {
    return this.a2uiBridge;
  }

  private makeCanvasInvokeHandler(): CanvasInvokeHandler {
    return new CanvasInvokeHandler({
      canvas: this.canvasWebHost,
      getNodeCanvasHost: () => this.nodeSession?.getCanvasHostUrl() ?? null,
      getOperatorCanvasHost: () => this.operatorSession?.getCanvasHostUrl() ?? null,
      refreshNodeCanvasCapability: () => {
        const s = this.nodeSession;
        return s ? s.refreshNodeCanvasCapability() : Promise.resolve(false);
      },
      onNavigate: () => {
        this.handleCanvasNavigationQueued();
      },
      onA2uiPush: () => {
        this.canvasA2uiHydrated = true;
        this.canvasRehydratePending = false;
        this.canvasRehydrateErrorText = null;
        this.notifyCanvasUi();
      },
      onA2uiReset: () => {
        this.canvasA2uiHydrated = false;
        this.canvasRehydratePending = false;
        this.canvasRehydrateErrorText = null;
        if (this.canvasWebHost.isDefaultScaffold()) {
          this.didAutoRequestCanvasRehydrate = false;
        }
        this.notifyCanvasUi();
      },
    });
  }

  private resolveMainSessionKey(): string {
    const k = (this.gatewayMainSessionKey ?? this.operatorSession?.getMainSessionKey() ?? "").trim();
    return k.length > 0 ? k : "main";
  }

  private resolveA2uiHostUrl(): string | null {
    const nodeRaw = (this.nodeSession?.getCanvasHostUrl() ?? "").trim();
    const opRaw = (this.operatorSession?.getCanvasHostUrl() ?? "").trim();
    const raw = nodeRaw.length > 0 ? nodeRaw : opRaw;
    if (raw.length === 0) {
      return null;
    }
    return `${raw.replace(/\/+$/, "")}/__openclaw__/a2ui/?platform=harmony`;
  }

  private normalizedSummaryText(value: string | null | undefined): string | null {
    const trimmed = (value ?? "").trim();
    return trimmed.length > 0 ? trimmed : null;
  }

  private normalizeMainSessionKey(value: string | null | undefined): string {
    const trimmed = (value ?? "").trim();
    return trimmed.length > 0 ? trimmed : "main";
  }

  private resolveAgentIdFromMainSessionKey(value: string | null | undefined): string | null {
    const trimmed = (value ?? "").trim();
    if (!trimmed.startsWith("agent:")) {
      return null;
    }
    const agentId = trimmed.substring("agent:".length).split(":")[0].trim();
    return agentId.length > 0 ? agentId : null;
  }

  private resolveHomeCanvasGatewayState(): string {
    if (this._isConnected) {
      return "connected";
    }
    const status = this._statusText.toLowerCase();
    if (status.includes("connecting") || status.includes("reconnecting")) {
      return "connecting";
    }
    if (status.includes("error") || status.includes("failed")) {
      return "error";
    }
    return "offline";
  }

  private resolveActiveAgentId(): string {
    const mainKey = this.resolveMainSessionKey();
    if (mainKey.startsWith("agent:")) {
      const agentId = mainKey.substring("agent:".length).split(":")[0].trim();
      if (agentId.length > 0) {
        return agentId;
      }
    }
    return (this.gatewayDefaultAgentId ?? "").trim();
  }

  private resolveActiveAgentName(activeAgentId: string): string {
    if (activeAgentId.length > 0) {
      for (let i = 0; i < this.gatewayAgents.length; i++) {
        const agent = this.gatewayAgents[i];
        if (agent.id === activeAgentId) {
          return this.normalizedSummaryText(agent.name) ?? agent.id;
        }
      }
      return activeAgentId;
    }
    return this.gatewayAgents.length > 0
      ? this.normalizedSummaryText(this.gatewayAgents[0].name) ?? this.gatewayAgents[0].id
      : "Main";
  }

  private buildHomeCanvasBadge(agent: GatewayAgentSummaryShape): string {
    const emoji = this.normalizedSummaryText(agent.emoji);
    if (emoji !== null) {
      return emoji;
    }
    const source = this.normalizedSummaryText(agent.name) ?? agent.id;
    const tokens = source.split(/[\s\-_]+/).filter((token) => token.trim().length > 0).slice(0, 2);
    let initials = "";
    for (let i = 0; i < tokens.length; i++) {
      const ch = tokens[i].trim().charAt(0);
      if (ch.length > 0) {
        initials += ch.toUpperCase();
      }
    }
    return initials.length > 0 ? initials : "OC";
  }

  private buildHomeCanvasAgents(activeAgentId: string): HomeCanvasAgentCardShape[] {
    const defaultAgentId = (this.gatewayDefaultAgentId ?? "").trim();
    const cards: HomeCanvasAgentCardShape[] = [];
    for (let i = 0; i < this.gatewayAgents.length; i++) {
      const agent = this.gatewayAgents[i];
      const isActive = activeAgentId.length > 0 && agent.id === activeAgentId;
      const isDefault = defaultAgentId.length > 0 && agent.id === defaultAgentId;
      cards.push({
        id: agent.id,
        name: this.normalizedSummaryText(agent.name) ?? agent.id,
        badge: this.buildHomeCanvasBadge(agent),
        caption: isActive ? "Active on this phone" : (isDefault ? "Default agent" : "Ready"),
        isActive: isActive,
      });
    }
    cards.sort((a, b) => {
      if (a.isActive !== b.isActive) {
        return a.isActive ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return cards;
  }

  private clearHomeCanvasOverview(): void {
    this.gatewayServerName = null;
    this.gatewayMainSessionKey = null;
    this.gatewayDefaultAgentId = null;
    this.gatewayAgents = [];
  }

  private showLocalCanvasOnConnect(): void {
    this.canvasA2uiHydrated = false;
    this.canvasRehydratePending = false;
    this.canvasRehydrateErrorText = null;
    this.canvasWebHost.navigate("");
    this.handleCanvasNavigationQueued();
  }

  private showLocalCanvasOnDisconnect(): void {
    this.canvasA2uiHydrated = false;
    this.canvasRehydratePending = false;
    this.canvasRehydrateErrorText = null;
    this.canvasWebHost.navigate("");
    this.handleCanvasNavigationQueued();
  }

  private handleCanvasNavigationQueued(): void {
    if (!this.canvasWebHost.isDefaultScaffold()) {
      this.canvasRehydratePending = false;
      this.canvasRehydrateErrorText = null;
    }
    this.canvasA2uiHydrated = false;
    this.canvasPageLoading = true;
    this.canvasPageErrorText = null;
    this.canvasPageErrorDetail = null;
    this.notifyCanvasUi();
  }

  private async refreshAgentsFromGateway(): Promise<void> {
    const session = this.operatorSession;
    if (!session || !this.operatorConnected) {
      return;
    }
    try {
      const res = await session.request("agents.list", {}, 10000);
      if (!res.ok || !res.payloadJson) {
        return;
      }
      const root = JSON.parse(res.payloadJson) as Record<string, object | string | number | boolean | null>;
      const defaultAgentId = String(root["defaultId"] ?? "").trim();
      const mainKeyValue = root["mainKey"];
      const mainKey = typeof mainKeyValue === "string" ? this.normalizeMainSessionKey(mainKeyValue) : "main";
      const agentsRaw = root["agents"];
      const nextAgents: GatewayAgentSummaryShape[] = [];
      if (Array.isArray(agentsRaw)) {
        const agentItems = agentsRaw as object[];
        for (let i = 0; i < agentItems.length; i++) {
          const item: object = agentItems[i];
          if (!item || typeof item !== "object") {
            continue;
          }
          const obj = item as Record<string, object | string | number | boolean | null>;
          const idValue = obj["id"];
          const id = typeof idValue === "string" ? idValue.trim() : "";
          if (id.length === 0) {
            continue;
          }
          const nameValue = obj["name"];
          const name = typeof nameValue === "string" ? this.normalizedSummaryText(nameValue) : null;
          const identityRaw = obj["identity"];
          let emoji: string | null = null;
          if (identityRaw && typeof identityRaw === "object") {
            const identity = identityRaw as Record<string, object | string | number | boolean | null>;
            const emojiValue = identity["emoji"];
            emoji = typeof emojiValue === "string" ? this.normalizedSummaryText(emojiValue) : null;
          }
          nextAgents.push({
            id: id,
            name: name,
            emoji: emoji,
          });
        }
      }
      this.gatewayMainSessionKey = mainKey;
      this.gatewayDefaultAgentId = defaultAgentId.length > 0 ? defaultAgentId : null;
      this.gatewayAgents = nextAgents;
      this.chatController?.applyMainSessionKey(mainKey);
      this.updateHomeCanvasState();
    } catch {
      // best-effort
    }
  }

  private buildHomeCanvasPayloadJson(): string {
    const gatewayState = this.resolveHomeCanvasGatewayState();
    const gatewayName = this.normalizedSummaryText(this.gatewayServerName);
    const gatewayAddress = this.normalizedSummaryText(this._remoteAddress);
    const gatewayLabel = gatewayName ?? gatewayAddress ?? "Gateway";
    const activeAgentId = this.resolveActiveAgentId();
    const agents = this.buildHomeCanvasAgents(activeAgentId);
    const payload: HomeCanvasPayloadShape = {
      gatewayState: gatewayState,
      eyebrow: gatewayState === "connected" ? `Connected to ${gatewayLabel}` :
        gatewayState === "connecting" ? "Reconnecting" : "Welcome to OpenClaw",
      title: gatewayState === "connected" ? "Your agents are ready" :
        gatewayState === "connecting" ? "OpenClaw is syncing back up" :
        "Your phone stays quiet until it is needed",
      subtitle: gatewayState === "connected"
        ? "This phone stays dormant until the gateway needs it, then wakes, syncs, and goes back to sleep."
        : gatewayState === "connecting"
          ? "The gateway session is coming back online. Agent shortcuts should settle automatically in a moment."
          : "Pair this device to your gateway to wake it only for real work, keep a live agent overview handy, and avoid battery-draining background loops.",
      gatewayLabel: gatewayLabel,
      activeAgentName: gatewayState === "offline" || gatewayState === "error"
        ? "Main"
        : this.resolveActiveAgentName(activeAgentId),
      activeAgentBadge: gatewayState === "connected"
        ? (agents.find((agent) => agent.isActive)?.badge ?? "OC")
        : "OC",
      activeAgentCaption: gatewayState === "connected"
        ? "Selected on this phone"
        : gatewayState === "connecting"
          ? "Gateway session in progress"
          : "Connect to load your agents",
      agentCount: agents.length,
      agents: gatewayState === "connected" ? agents.slice(0, 6) : agents.slice(0, 4),
      footer: gatewayState === "connected"
        ? "The overview refreshes on reconnect and when this screen opens."
        : gatewayState === "connecting"
          ? "If the gateway is reachable, reconnect should complete without intervention."
          : "When connected, the gateway can wake the phone with a silent push instead of holding an always-on session.",
    };
    return JSON.stringify(payload);
  }

  private updateHomeCanvasState(): void {
    this.canvasWebHost.setHomeStateJson(this.buildHomeCanvasPayloadJson());
  }

  private startNotificationForwardingLoop(): void {
    if (this.notificationForwardPollTimer !== null) {
      return;
    }
    this.notificationForwardPollTimer = setInterval(() => {
      void this.pollNotificationForwarding();
    }, 2000) as number;
  }

  private resetNotificationForwardingBaseline(): void {
    this.notificationForwardingBaselineReady = false;
    this.notificationSnapshotByKey.clear();
    this.notificationForwardingTimestamps = [];
  }

  private buildNotificationSnapshotByKey(entries: StoredNotificationEntry[]): Map<string, StoredNotificationEntry> {
    const byKey = new Map<string, StoredNotificationEntry>();
    for (let i = 0; i < entries.length; i++) {
      byKey.set(entries[i].key, entries[i]);
    }
    return byKey;
  }

  private notificationEntryChanged(previous: StoredNotificationEntry, next: StoredNotificationEntry): boolean {
    return (
      previous.packageName !== next.packageName ||
      previous.title !== next.title ||
      previous.text !== next.text ||
      previous.subText !== next.subText ||
      previous.category !== next.category ||
      previous.channelId !== next.channelId ||
      previous.postTimeMs !== next.postTimeMs ||
      previous.isOngoing !== next.isOngoing ||
      previous.isClearable !== next.isClearable
    );
  }

  private allowNotificationForwardingEvent(nowEpochMs: number, maxEventsPerMinute: number): boolean {
    const windowStart = nowEpochMs - 60000;
    const nextTimestamps = this.notificationForwardingTimestamps.filter((value) => value >= windowStart);
    if (nextTimestamps.length >= maxEventsPerMinute) {
      this.notificationForwardingTimestamps = nextTimestamps;
      return false;
    }
    nextTimestamps.push(nowEpochMs);
    this.notificationForwardingTimestamps = nextTimestamps;
    return true;
  }

  private normalizeNotificationForwardingPackages(values: string[]): string[] {
    const deduped = new Set<string>();
    const normalized: string[] = [];
    for (let i = 0; i < values.length; i++) {
      const value = values[i].trim();
      if (value.length === 0 || deduped.has(value)) {
        continue;
      }
      deduped.add(value);
      normalized.push(value);
    }
    return normalized;
  }

  private parseNotificationForwardingPackages(raw: string): string[] {
    if (raw.trim().length === 0) {
      return [];
    }
    const parts = raw.split(/[\n,]/);
    return this.normalizeNotificationForwardingPackages(parts);
  }

  private async readNotificationForwardingPolicy(): Promise<NotificationForwardingPolicy> {
    const sessionKey = (await this.getNotificationForwardingSessionKey()).trim();
    const mode = await this.getNotificationForwardingMode();
    const configuredPackages = await this.getNotificationForwardingPackages();
    let packages = configuredPackages;
    if (mode === NotificationPackageFilterMode.Blocklist) {
      const nextPackages: string[] = [];
      for (let i = 0; i < configuredPackages.length; i++) {
        nextPackages.push(configuredPackages[i]);
      }
      nextPackages.push(NodeRuntime.NOTIFICATION_FORWARDING_DEFAULT_BLOCKED_PACKAGE);
      packages = this.normalizeNotificationForwardingPackages(nextPackages);
    }
    return {
      enabled: await this.getNotificationForwardingEnabled(),
      mode,
      packages,
      quietHoursEnabled: await this.getNotificationForwardingQuietHoursEnabled(),
      quietStart: await this.getNotificationForwardingQuietStart(),
      quietEnd: await this.getNotificationForwardingQuietEnd(),
      maxEventsPerMinute: await this.getNotificationForwardingMaxEventsPerMinute(),
      sessionKey: sessionKey.length > 0 ? sessionKey : null,
    };
  }

  private async pollNotificationForwarding(): Promise<void> {
    try {
      const snapshot = await this.notificationStore.readSnapshot();
      const nextByKey = this.buildNotificationSnapshotByKey(snapshot.notifications);
      const policy = await this.readNotificationForwardingPolicy();
      const session = this.nodeSession;
      const canEmit = this._isConnected && session !== null && policy.enabled;
      if (!canEmit) {
        this.notificationSnapshotByKey = nextByKey;
        this.notificationForwardingBaselineReady = false;
        this.notificationForwardingTimestamps = [];
        return;
      }

      if (!this.notificationForwardingBaselineReady) {
        this.notificationSnapshotByKey = nextByKey;
        this.notificationForwardingBaselineReady = true;
        return;
      }

      for (let i = snapshot.notifications.length - 1; i >= 0; i--) {
        const entry = snapshot.notifications[i];
        const previous = this.notificationSnapshotByKey.get(entry.key);
        if (previous && !this.notificationEntryChanged(previous, entry)) {
          continue;
        }
        await this.forwardNotificationChangedEvent(session, policy, "posted", entry);
      }

      const removedEntries = Array.from(this.notificationSnapshotByKey.values());
      for (let i = 0; i < removedEntries.length; i++) {
        const previous = removedEntries[i];
        if (nextByKey.has(previous.key)) {
          continue;
        }
        await this.forwardNotificationChangedEvent(session, policy, "removed", previous);
      }

      this.notificationSnapshotByKey = nextByKey;
    } catch {
      // Keep forwarding best-effort; polling should never break the main runtime.
    }
  }

  private async forwardNotificationChangedEvent(
    session: GatewaySession,
    policy: NotificationForwardingPolicy,
    change: string,
    entry: StoredNotificationEntry,
  ): Promise<void> {
    if (!allowsNotificationPackage(policy, entry.packageName)) {
      return;
    }
    const nowEpochMs = Date.now();
    if (isWithinQuietHours(policy.quietHoursEnabled, policy.quietStart, policy.quietEnd, nowEpochMs)) {
      return;
    }
    if (!this.allowNotificationForwardingEvent(nowEpochMs, policy.maxEventsPerMinute)) {
      return;
    }
    const payload: NotificationChangedPayloadShape = {
      change,
      key: entry.key,
      packageName: entry.packageName,
      postTimeMs: entry.postTimeMs,
      isOngoing: entry.isOngoing,
      isClearable: entry.isClearable,
    };
    if (policy.sessionKey) {
      payload.sessionKey = policy.sessionKey;
    }
    if (change === "posted") {
      if (entry.title) {
        payload.title = entry.title;
      }
      if (entry.text) {
        payload.text = entry.text;
      }
      if (entry.subText) {
        payload.subText = entry.subText;
      }
      if (entry.category) {
        payload.category = entry.category;
      }
      if (entry.channelId) {
        payload.channelId = entry.channelId;
      }
    }
    try {
      await session.sendNodeEvent("notifications.changed", JSON.stringify(payload));
    } catch {
      // Ignore transient send errors; the next snapshot change will retry.
    }
  }

  async refreshHomeCanvasOverviewIfConnected(): Promise<void> {
    if (!this.operatorConnected) {
      this.updateHomeCanvasState();
      return;
    }
    await Promise.all([
      this.refreshAgentsFromGateway(),
      this.refreshGatewayMainSessionFromOperator(),
    ]);
    this.updateHomeCanvasState();
  }

  private resetCanvasRehydrateState(): void {
    this.didAutoRequestCanvasRehydrate = false;
    this.canvasA2uiHydrated = false;
    this.canvasRehydratePending = false;
    this.canvasRehydrateErrorText = null;
    this.canvasPageLoading = false;
    this.canvasPageErrorText = null;
    this.canvasPageErrorDetail = null;
    this.notifyCanvasUi();
  }

  private snapshotCanvasUi(): CanvasUiState {
    return {
      a2uiHydrated: this.canvasA2uiHydrated,
      rehydratePending: this.canvasRehydratePending,
      rehydrateErrorText: this.canvasRehydrateErrorText,
      pageLoading: this.canvasPageLoading,
      pageErrorText: this.canvasPageErrorText,
      pageErrorDetail: this.canvasPageErrorDetail,
      targetUrl: this.canvasWebHost.getTargetUrl(),
      currentUrl: this.canvasWebHost.getCurrentUrl(),
      isDefaultScaffold: this.canvasWebHost.isDefaultScaffold(),
    };
  }

  private notifyCanvasUi(): void {
    this.canvasUiListener?.(this.snapshotCanvasUi());
  }

  private notifyGatewayTrust(): void {
    this.gatewayTrustListener?.(this.pendingGatewayTrust);
  }

  syncCanvasCurrentUrlFromController(): void {
    const previousUrl = this.canvasWebHost.getCurrentUrl() ?? '';
    const nextUrl = this.canvasWebHost.refreshCurrentUrlFromController() ?? '';
    if (previousUrl === nextUrl) {
      return;
    }
    this.notifyCanvasUi();
  }

  setCanvasUiListener(listener: ((state: CanvasUiState) => void) | null): void {
    this.canvasUiListener = listener;
    if (listener) {
      listener(this.snapshotCanvasUi());
    }
  }

  setGatewayTrustListener(listener: ((prompt: GatewayTrustPrompt | null) => void) | null): void {
    this.gatewayTrustListener = listener;
    if (listener) {
      listener(this.pendingGatewayTrust);
    }
  }

  getPendingGatewayTrustPrompt(): GatewayTrustPrompt | null {
    return this.pendingGatewayTrust;
  }

  async requestCanvasRehydrate(source: string = "manual", force: boolean = true): Promise<void> {
    if (!this.nodeSession || !this.nodeConnected) {
      this.canvasRehydratePending = false;
      this.canvasRehydrateErrorText = "Node offline. Reconnect and retry.";
      this.notifyCanvasUi();
      return;
    }
    if (!force && this.didAutoRequestCanvasRehydrate) {
      return;
    }
    this.didAutoRequestCanvasRehydrate = true;
    const requestId = ++this.canvasRehydrateSeq;
    this.canvasRehydratePending = true;
    this.canvasRehydrateErrorText = null;
    this.notifyCanvasUi();

    const sessionKey = this.resolveMainSessionKey();
    const prompt =
      `Restore canvas now for session=${sessionKey} source=${source}. ` +
      'If existing A2UI state exists, replay it immediately. ' +
      'If not, create and render a compact mobile-friendly dashboard in Canvas.';
    const payload: CanvasRehydrateRequestPayloadShape = {
      message: prompt,
      sessionKey: sessionKey,
      thinking: "low",
      deliver: false,
    };
    const sent = await this.nodeSession.sendNodeEvent("agent.request", JSON.stringify(payload));
    if (!sent) {
      if (!force) {
        this.didAutoRequestCanvasRehydrate = false;
      }
      if (this.canvasRehydrateSeq === requestId) {
        this.canvasRehydratePending = false;
        this.canvasRehydrateErrorText = "Failed to request restore. Tap to retry.";
        this.notifyCanvasUi();
      }
      return;
    }
    setTimeout(() => {
      if (this.canvasRehydrateSeq !== requestId) {
        return;
      }
      if (!this.canvasRehydratePending || this.canvasA2uiHydrated) {
        return;
      }
      this.canvasRehydratePending = false;
      this.canvasRehydrateErrorText = "No canvas update yet. Tap to retry.";
      this.notifyCanvasUi();
    }, 20000);
  }

  private normalizeCanvasText(value: string | null | undefined): string | null {
    const trimmed = (value ?? "").trim();
    return trimmed.length > 0 ? trimmed : null;
  }

  private async refreshGatewayMainSessionFromOperator(): Promise<void> {
    const session = this.operatorSession;
    if (!session || !this.operatorConnected) {
      return;
    }
    try {
      const nextMainKey = this.normalizeMainSessionKey(session.getMainSessionKey());
      if (nextMainKey === this.gatewayMainSessionKey) {
        return;
      }
      this.gatewayMainSessionKey = nextMainKey;
      this.chatController?.applyMainSessionKey(nextMainKey);
      this.notifyCanvasUi();
    } catch {
      // best-effort
    }
  }

  private logCanvasInfo(message: string, ...args: string[]): void {
    if (!this.canvasDebugEnabled) {
      return;
    }
    hilog.info(LOG_DOMAIN, CANVAS_LOG_TAG, message, ...args);
  }

  private logCanvasWarn(message: string, ...args: string[]): void {
    hilog.warn(LOG_DOMAIN, CANVAS_LOG_TAG, message, ...args);
  }

  onCanvasPageStarted(url?: string | null): void {
    const normalizedUrl = this.normalizeCanvasText(url);
    if (normalizedUrl !== null) {
      this.canvasWebHost.setCurrentUrl(normalizedUrl);
    } else {
      this.canvasWebHost.refreshCurrentUrlFromController();
    }
    if (!this.canvasWebHost.isDefaultScaffold()) {
      this.canvasRehydratePending = false;
      this.canvasRehydrateErrorText = null;
    }
    this.canvasA2uiHydrated = false;
    this.canvasPageLoading = true;
    this.canvasPageErrorText = null;
    this.canvasPageErrorDetail = null;
    this.logCanvasInfo('onPageStarted url=%{public}s', normalizedUrl ?? this.canvasWebHost.getDisplayUrl());
    this.notifyCanvasUi();
  }

  onCanvasPageFinished(url?: string | null): void {
    const normalizedUrl = this.normalizeCanvasText(url);
    if (normalizedUrl !== null) {
      this.canvasWebHost.setCurrentUrl(normalizedUrl);
    } else {
      this.canvasWebHost.refreshCurrentUrlFromController();
    }
    if (!this.canvasWebHost.isDefaultScaffold()) {
      this.canvasRehydratePending = false;
      this.canvasRehydrateErrorText = null;
      this.didAutoRequestCanvasRehydrate = false;
    }
    this.canvasPageLoading = false;
    this.logCanvasInfo(
      'onPageFinished url=%{public}s',
      this.canvasWebHost.getCurrentUrl() ?? this.canvasWebHost.getDisplayUrl(),
    );
    this.notifyCanvasUi();
  }

  onCanvasPageFailed(summary: string, detail?: string | null, url?: string | null): void {
    const normalizedUrl = this.normalizeCanvasText(url);
    if (normalizedUrl !== null) {
      this.canvasWebHost.setCurrentUrl(normalizedUrl);
    }
    this.canvasRehydratePending = false;
    if (this.canvasWebHost.isDefaultScaffold()) {
      this.didAutoRequestCanvasRehydrate = false;
    } else {
      this.canvasRehydrateErrorText = null;
    }
    this.canvasA2uiHydrated = false;
    this.canvasPageLoading = false;
    this.canvasPageErrorText = this.normalizeCanvasText(summary) ?? "Canvas page failed to load.";
    this.canvasPageErrorDetail = this.normalizeCanvasText(detail);
    this.logCanvasWarn(
      'onPageFailed summary=%{public}s detail=%{public}s url=%{public}s',
      this.canvasPageErrorText ?? '',
      this.canvasPageErrorDetail ?? '',
      normalizedUrl ?? this.canvasWebHost.getDisplayUrl(),
    );
    this.notifyCanvasUi();
  }

  reloadCanvasPage(): void {
    if (this.canvasWebHost.isDefaultScaffold()) {
      this.didAutoRequestCanvasRehydrate = false;
    }
    this.canvasA2uiHydrated = false;
    this.canvasRehydratePending = false;
    this.canvasRehydrateErrorText = null;
    this.canvasPageLoading = true;
    this.canvasPageErrorText = null;
    this.canvasPageErrorDetail = null;
    this.logCanvasInfo('reloadCanvasPage target=%{public}s', this.canvasWebHost.getDisplayUrl());
    this.notifyCanvasUi();
    this.canvasWebHost.reloadCurrent();
  }

  private randomActionId(): string {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  async handleCanvasA2UIActionFromWebView(payloadJson: string): Promise<void> {
    const trimmed = payloadJson.trim();
    if (trimmed.length === 0) {
      return;
    }
    let root: Record<string, object | string | number | boolean | null>;
    try {
      root = JSON.parse(trimmed) as Record<string, object | string | number | boolean | null>;
    } catch {
      return;
    }
    const userActionRaw = root["userAction"];
    const userActionObj: A2UIUserActionMap =
      typeof userActionRaw === "object" && userActionRaw !== null
        ? (userActionRaw as A2UIUserActionMap)
        : (root as A2UIUserActionMap);
    let actionId = String(userActionObj["id"] ?? "").trim();
    if (actionId.length === 0) {
      actionId = this.randomActionId();
    }
    const name = extractActionName(userActionObj);
    if (!name) {
      return;
    }
    const trustedBase = this.resolveA2uiHostUrl();
    const current = this.canvasWebHost.getCurrentUrl();
    const trustedList = trustedBase ? [trustedBase] : [];
    if (!isTrustedCanvasActionUrl(current, trustedList)) {
      return;
    }
    const surfaceId = String(userActionObj["surfaceId"] ?? "").trim() || "main";
    const sourceComponentId = String(userActionObj["sourceComponentId"] ?? "").trim() || "-";
    const ctxRaw = userActionObj["context"];
    const contextJson =
      typeof ctxRaw === "object" && ctxRaw !== null ? JSON.stringify(ctxRaw) : null;
    const sessionKey = this.resolveMainSessionKey();
    const displayName = await this.getDisplayName();
    const instanceId = (await this.getInstanceId()).toLowerCase();
    const message = formatAgentMessage(
      name,
      sessionKey,
      surfaceId,
      sourceComponentId,
      displayName,
      instanceId,
      contextJson,
    );
    const node = this.nodeSession;
    let error: string | null = null;
    if (node) {
      const payload = JSON.stringify({
        message,
        sessionKey,
        thinking: "low",
        deliver: false,
        key: actionId,
      });
      const sent = await node.sendNodeEvent("agent.request", payload);
      if (!sent) {
        error = "send failed";
      }
    } else {
      error = "gateway not connected";
    }
    const statusJs = jsDispatchA2UIActionStatus(actionId, error === null, error);
    try {
      await this.canvasWebHost.runJavaScript(statusJs);
    } catch {
      // ignore
    }
  }

  setOnboardingListener(listener: ((completed: boolean) => void) | null): void {
    this._onboardingListener = listener;
    if (listener) {
      listener(this._onboardingCompleted);
    }
  }

  getOnboardingCompleted(): boolean {
    return this._onboardingCompleted;
  }

  async setOnboardingCompleted(completed: boolean): Promise<void> {
    this._onboardingCompleted = completed;
    await this.prefs.putBoolean("onboarding.completed", completed);
    this._onboardingListener?.(completed);
  }

  setStatusListener(listener: StatusListener | null): void {
    this.statusListener = listener;
  }

  setCameraHudListener(listener: ((state: CameraHudState | null) => void) | null): void {
    this.cameraHudListener = listener;
    listener?.(this.copyCameraHudState(this.cameraHud));
  }

  setCameraFlashListener(listener: ((token: number) => void) | null): void {
    this.cameraFlashListener = listener;
    listener?.(this.cameraFlashToken);
  }

  private copyCameraHudState(state: CameraHudState | null): CameraHudState | null {
    if (state === null) {
      return null;
    }
    return {
      token: state.token,
      kind: state.kind,
      message: state.message,
    };
  }

  private notifyCameraHud(): void {
    this.cameraHudListener?.(this.copyCameraHudState(this.cameraHud));
  }

  private triggerCameraFlash(): void {
    this.cameraFlashToken += 1;
    this.cameraFlashListener?.(this.cameraFlashToken);
  }

  private showCameraHud(message: string, kind: CameraHudKind, autoHideMs: number | null = null): void {
    if (this.cameraHudTimer >= 0) {
      clearTimeout(this.cameraHudTimer);
      this.cameraHudTimer = -1;
    }
    const token = ++this.cameraHudSeq;
    this.cameraHud = { token, kind, message };
    this.notifyCameraHud();
    if (autoHideMs !== null && autoHideMs > 0) {
      this.cameraHudTimer = setTimeout(() => {
        this.cameraHudTimer = -1;
        if (this.cameraHud?.token === token) {
          this.cameraHud = null;
          this.notifyCameraHud();
        }
      }, autoHideMs) as number;
    }
  }

  private notifyStatus(): void {
    this.voiceCoordinator.onGatewayConnectionChanged(this._isConnected);
    void this.syncVoiceWakeState();
    this.statusListener?.({
      statusText: this._statusText,
      isConnected: this._isConnected,
      remoteAddress: this._remoteAddress,
    });
    this.updateHomeCanvasState();
    void this.syncCanvasDebugOverlay();
  }

  private updateStatus(): void {
    this._isConnected = this.operatorConnected;
    const operator = this.operatorStatusText.trim();
    const node = this.nodeStatusText.trim();
    this._statusText =
      this.operatorConnected && this.nodeConnected ? "Connected" :
        this.operatorConnected && !this.nodeConnected ? "Connected (node offline)" :
          !this.operatorConnected && this.nodeConnected
            ? (operator.length > 0 && operator !== "Offline"
              ? `Connected (operator: ${operator})`
              : "Connected (operator offline)")
            : operator.length > 0 && operator !== "Offline"
              ? operator
              : node;
    this.notifyStatus();
  }

  private syncCanvasDebugOverlay(): void {
    void this.prefs.getBooleanOr("canvas.debug.enabled", false).then((en) => {
      if (en) {
        const server = this.normalizedSummaryText(this.gatewayServerName);
        const remote = this._remoteAddress.trim().length > 0 ? this._remoteAddress : null;
        const sub = server ?? remote;
        this.canvasWebHost.setDebugStatus(true, this._statusText, sub);
      } else {
        this.canvasWebHost.setDebugStatus(false, null, null);
      }
    });
  }

  private hasAnyPermission(permissionNames: Permissions[]): boolean {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenId = this.context.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = atManager.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch {
        // Ignore permission names unsupported on this build.
      }
    }
    return false;
  }

  async getCanvasDebugEnabled(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr("canvas.debug.enabled", false);
    this.canvasDebugEnabled = enabled;
    return enabled;
  }

  async setCanvasDebugEnabled(enabled: boolean): Promise<void> {
    this.canvasDebugEnabled = enabled;
    await this.prefs.putBoolean("canvas.debug.enabled", enabled);
    this.syncCanvasDebugOverlay();
  }

  async getCameraEnabled(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.CAMERA_ENABLED_KEY, true);
    this._cameraEnabled = enabled;
    return enabled;
  }

  getCameraEnabledSync(): boolean {
    return this._cameraEnabled;
  }

  async setCameraEnabled(enabled: boolean): Promise<void> {
    this._cameraEnabled = enabled;
    await this.prefs.putBoolean(NodeRuntime.CAMERA_ENABLED_KEY, enabled);
  }

  async getLocationMode(): Promise<LocationMode> {
    const raw = await this.prefs.getString(NodeRuntime.LOCATION_MODE_KEY);
    const mode = locationModeFromRaw(raw);
    this._locationMode = mode;
    if (raw !== mode) {
      await this.prefs.putString(NodeRuntime.LOCATION_MODE_KEY, mode);
    }
    return mode;
  }

  getLocationModeSync(): LocationMode {
    return this._locationMode;
  }

  async setLocationMode(mode: LocationMode): Promise<void> {
    this._locationMode = mode;
    await this.prefs.putString(NodeRuntime.LOCATION_MODE_KEY, mode);
  }

  async getLocationPreciseEnabled(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.LOCATION_PRECISE_ENABLED_KEY, true);
    this._locationPreciseEnabled = enabled;
    return enabled;
  }

  getLocationPreciseEnabledSync(): boolean {
    return this._locationPreciseEnabled;
  }

  async setLocationPreciseEnabled(enabled: boolean): Promise<void> {
    this._locationPreciseEnabled = enabled;
    await this.prefs.putBoolean(NodeRuntime.LOCATION_PRECISE_ENABLED_KEY, enabled);
  }

  async getPreventSleep(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.PREVENT_SLEEP_KEY, true);
    this._preventSleep = enabled;
    return enabled;
  }

  getPreventSleepSync(): boolean {
    return this._preventSleep;
  }

  async setPreventSleep(enabled: boolean): Promise<void> {
    this._preventSleep = enabled;
    await this.prefs.putBoolean(NodeRuntime.PREVENT_SLEEP_KEY, enabled);
    await this.applyPreventSleepToWindow();
  }

  async getNotificationForwardingEnabled(): Promise<boolean> {
    return this.prefs.getBooleanOr(NodeRuntime.NOTIFICATION_FORWARDING_ENABLED_KEY, false);
  }

  async setNotificationForwardingEnabled(enabled: boolean): Promise<void> {
    await this.prefs.putBoolean(NodeRuntime.NOTIFICATION_FORWARDING_ENABLED_KEY, enabled);
    this.resetNotificationForwardingBaseline();
  }

  async getNotificationForwardingMode(): Promise<NotificationPackageFilterMode> {
    const raw = await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_MODE_KEY);
    const mode = notificationPackageFilterModeFromRaw(raw);
    if ((raw ?? "") !== mode) {
      await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_MODE_KEY, mode);
    }
    return mode;
  }

  async setNotificationForwardingMode(mode: NotificationPackageFilterMode): Promise<void> {
    await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_MODE_KEY, mode);
    this.resetNotificationForwardingBaseline();
  }

  async getNotificationForwardingPackages(): Promise<string[]> {
    const raw = (await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_PACKAGES_KEY)) ?? "";
    return this.parseNotificationForwardingPackages(raw);
  }

  async getNotificationForwardingPackagesCsv(): Promise<string> {
    const packages = await this.getNotificationForwardingPackages();
    return packages.join(", ");
  }

  async setNotificationForwardingPackagesCsv(value: string): Promise<void> {
    const packages = this.parseNotificationForwardingPackages(value);
    await this.prefs.putString(
      NodeRuntime.NOTIFICATION_FORWARDING_PACKAGES_KEY,
      packages.join(","),
    );
    this.resetNotificationForwardingBaseline();
  }

  async getRecentNotificationApps(): Promise<NotificationForwardingCandidateApp[]> {
    const snapshot = await this.notificationStore.readSnapshot();
    const recent: NotificationForwardingCandidateApp[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < snapshot.notifications.length; i++) {
      const entry = snapshot.notifications[i];
      const packageName = entry.packageName.trim();
      if (
        packageName.length === 0 ||
        packageName === NodeRuntime.NOTIFICATION_FORWARDING_DEFAULT_BLOCKED_PACKAGE ||
        seen.has(packageName)
      ) {
        continue;
      }
      seen.add(packageName);
      recent.push({
        packageName,
        label: this.normalizedSummaryText(entry.subText) ??
          this.normalizedSummaryText(entry.title) ??
          packageName,
      });
      if (recent.length >= 12) {
        break;
      }
    }
    return recent;
  }

  async getRecentNotificationPackages(): Promise<string[]> {
    const recentApps = await this.getRecentNotificationApps();
    const packages: string[] = [];
    for (let i = 0; i < recentApps.length; i++) {
      packages.push(recentApps[i].packageName);
    }
    return packages;
  }

  async getNotificationForwardingQuietHoursEnabled(): Promise<boolean> {
    return this.prefs.getBooleanOr(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_HOURS_ENABLED_KEY, false);
  }

  async getNotificationForwardingQuietStart(): Promise<string> {
    const stored = await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_START_KEY);
    return normalizeLocalHourMinute(stored ?? '') ?? NodeRuntime.NOTIFICATION_FORWARDING_DEFAULT_QUIET_START;
  }

  async getNotificationForwardingQuietEnd(): Promise<string> {
    const stored = await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_END_KEY);
    return normalizeLocalHourMinute(stored ?? '') ?? NodeRuntime.NOTIFICATION_FORWARDING_DEFAULT_QUIET_END;
  }

  async setNotificationForwardingQuietHours(enabled: boolean, start: string, end: string): Promise<boolean> {
    if (!enabled) {
      await this.prefs.putBoolean(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_HOURS_ENABLED_KEY, false);
      return true;
    }
    const normalizedStart = normalizeLocalHourMinute(start);
    const normalizedEnd = normalizeLocalHourMinute(end);
    if (!normalizedStart || !normalizedEnd) {
      return false;
    }
    await this.prefs.putBoolean(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_HOURS_ENABLED_KEY, true);
    await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_START_KEY, normalizedStart);
    await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_QUIET_END_KEY, normalizedEnd);
    return true;
  }

  async getNotificationForwardingMaxEventsPerMinute(): Promise<number> {
    const raw = await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_MAX_EVENTS_KEY);
    const parsed = raw ? parseInt(raw, 10) : NaN;
    return Number.isFinite(parsed) && parsed >= 1 ? parsed : 30;
  }

  async setNotificationForwardingMaxEventsPerMinute(value: number): Promise<void> {
    const normalized = Math.max(1, Math.floor(value));
    await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_MAX_EVENTS_KEY, String(normalized));
  }

  async getNotificationForwardingSessionKey(): Promise<string> {
    return (await this.prefs.getString(NodeRuntime.NOTIFICATION_FORWARDING_SESSION_KEY)) ?? "";
  }

  async setNotificationForwardingSessionKey(value: string): Promise<void> {
    await this.prefs.putString(NodeRuntime.NOTIFICATION_FORWARDING_SESSION_KEY, value.trim());
    this.resetNotificationForwardingBaseline();
  }

  bindMainWindow(mainWindow: window.Window): void {
    this.mainWindow = mainWindow;
    void this.applyPreventSleepToWindow();
  }

  unbindMainWindow(): void {
    this.mainWindow = null;
  }

  private async applyPreventSleepToWindow(): Promise<void> {
    const mainWindow = this.mainWindow;
    if (!mainWindow) {
      return;
    }
    try {
      await mainWindow.setWindowKeepScreenOn(this._preventSleep);
    } catch {
      // Best-effort only; keep the preference even if the API is unavailable on this build.
    }
  }

  setVoiceUiListener(listener: VoiceStateListener | null): void {
    this.voiceCoordinator.setUiListener(listener);
  }

  async setVoiceMicEnabled(enabled: boolean): Promise<void> {
    await this.voiceCoordinator.setMicEnabled(enabled);
    await this.syncVoiceWakeState();
  }

  async setTalkModeEnabled(enabled: boolean): Promise<void> {
    await this.voiceCoordinator.setTalkModeEnabled(enabled);
    await this.syncVoiceWakeState();
  }

  async setVoiceSpeakerEnabled(enabled: boolean): Promise<void> {
    await this.voiceCoordinator.setSpeakerEnabled(enabled);
  }

  async cancelVoicePendingTurn(): Promise<void> {
    await this.voiceCoordinator.cancelPendingTurn();
  }

  getVoiceSpeakerEnabled(): boolean {
    return this.voiceCoordinator.getSpeakerEnabled();
  }

  setVoiceScreenActive(active: boolean): void {
    this.voiceCoordinator.setVoiceScreenActive(active);
  }

  setForegroundActive(active: boolean): void {
    this.foregroundActive = active;
    void this.syncVoiceWakeState();
  }

  getVoiceMicEnabled(): boolean {
    return this.voiceCoordinator.getMicEnabled();
  }

  getVoiceMicCooldown(): boolean {
    return this.voiceCoordinator.getMicCooldown();
  }

  async getVoiceWakeMode(): Promise<VoiceWakeMode> {
    const raw = await this.prefs.getString(NodeRuntime.VOICE_WAKE_MODE_KEY);
    const mode = voiceWakeModeFromRaw(raw);
    this._voiceWakeMode = mode;
    if (raw !== mode) {
      await this.prefs.putString(NodeRuntime.VOICE_WAKE_MODE_KEY, mode);
    }
    return mode;
  }

  getVoiceWakeModeSync(): VoiceWakeMode {
    return this._voiceWakeMode;
  }

  async setVoiceWakeMode(mode: VoiceWakeMode): Promise<void> {
    this._voiceWakeMode = mode;
    await this.prefs.putString(NodeRuntime.VOICE_WAKE_MODE_KEY, mode);
    await this.syncVoiceWakeState();
  }

  async getVoiceWakeWords(): Promise<string[]> {
    const raw = await this.prefs.getString(NodeRuntime.VOICE_WAKE_TRIGGER_WORDS_KEY);
    if (!raw || raw.trim().length === 0) {
      const defaults = defaultWakeWords();
      this.voiceWakeManager.setTriggerWords(defaults);
      return defaults;
    }
    try {
      const parsed = JSON.parse(raw) as string[];
      const sanitized = sanitizeWakeWords(Array.isArray(parsed) ? parsed : [], defaultWakeWords());
      this.voiceWakeManager.setTriggerWords(sanitized);
      return sanitized;
    } catch {
      const defaults = defaultWakeWords();
      this.voiceWakeManager.setTriggerWords(defaults);
      return defaults;
    }
  }

  async getVoiceWakeWordsCsv(): Promise<string> {
    return (await this.getVoiceWakeWords()).join(", ");
  }

  async setVoiceWakeWordsCsv(raw: string): Promise<void> {
    await this.applyVoiceWakeWords(parseWakeWordsCsv(raw), true);
    await this.syncVoiceWakeState();
  }

  getVoiceWakeStatusText(): string {
    return this.voiceWakeManager.getStatusText();
  }

  getVoiceWakeListening(): boolean {
    return this.voiceWakeManager.isListening();
  }

  getStatusText(): string {
    return this._statusText;
  }

  getIsConnected(): boolean {
    return this._isConnected;
  }

  getRemoteAddress(): string {
    return this._remoteAddress;
  }

  getVersion(): string {
    return VERSION;
  }

  getDeviceModel(): string {
    const parts = [deviceInfo.manufacture, deviceInfo.productModel]
      .filter((s) => (s ?? "").trim().length > 0);
    return parts.join(" ").trim() || "HarmonyOS";
  }

  async getInstanceId(): Promise<string> {
    try {
      const identity = await this.identityStore.loadOrCreate();
      return identity.deviceId;
    } catch {
      return "";
    }
  }

  async getDisplayName(): Promise<string> {
    const stored = await this.prefs.getString("display.name");
    if (stored && stored.trim().length > 0) return stored.trim();
    const fallback = (deviceInfo.marketName ?? deviceInfo.productModel ?? "").trim();
    return fallback || "";
  }

  async setDisplayName(name: string): Promise<void> {
    await this.prefs.putString("display.name", (name ?? "").trim());
  }

  getChatController(): ChatController | null {
    return this.chatController;
  }

  private async resolveGatewayTlsCertPath(
    endpoint: GatewayEndpoint,
    stableId: string,
  ): Promise<string | null> {
    if (!endpoint.useTls) {
      return null;
    }

    const storedFingerprint = await getStoredFingerprint(this.prefs, stableId);
    if (!storedFingerprint) {
      this.pendingGatewayTrust = null;
      this.notifyGatewayTrust();
      this.operatorConnected = false;
      this.nodeConnected = false;
      this.operatorStatusText = "Verify gateway TLS fingerprint…";
      this.nodeStatusText = "Offline";
      this.updateStatus();
      const probe = await probeGatewayTlsCertificate(endpoint.host, endpoint.port);
      if (!probe) {
        throw new Error("Failed: can't read TLS fingerprint");
      }
      this.pendingGatewayTrust = {
        stableId,
        host: endpoint.host,
        port: endpoint.port,
        useTls: endpoint.useTls,
        fingerprintSha256: probe.fingerprintSha256,
        certPem: probe.pem,
      };
      this.notifyGatewayTrust();
      return null;
    }

    if (hasTrustedCertPath(this.context, stableId)) {
      return getTrustedCertPath(this.context, stableId);
    }

    const probe = await probeGatewayTlsCertificate(endpoint.host, endpoint.port);
    if (!probe) {
      return null;
    }
    if (probe.fingerprintSha256 !== storedFingerprint) {
      await clearStoredFingerprint(this.prefs, stableId);
      clearTrustedCertPath(this.context, stableId);
      this.pendingGatewayTrust = {
        stableId,
        host: endpoint.host,
        port: endpoint.port,
        useTls: endpoint.useTls,
        fingerprintSha256: probe.fingerprintSha256,
        certPem: probe.pem,
      };
      this.notifyGatewayTrust();
      this.operatorConnected = false;
      this.nodeConnected = false;
      this.operatorStatusText = "Gateway TLS fingerprint changed. Verify and trust again.";
      this.nodeStatusText = "Offline";
      this.updateStatus();
      return null;
    }
    return writeTrustedCertPem(this.context, stableId, probe.pem);
  }

  async connect(
    host: string,
    port: number,
    useTls: boolean,
    token: string,
    password: string,
    stableId: string | null = null,
  ): Promise<void> {
    this.disconnect();
    this.operatorConnected = false;
    this.nodeConnected = false;
    this.operatorStatusText = "Connecting…";
    this.nodeStatusText = "Connecting…";
    this.updateStatus();

    const endpoint: GatewayEndpoint = { host: host.trim(), port, useTls };
    const endpointStableId = stableId?.trim() || this.buildGatewayStableId(endpoint.host, endpoint.port, endpoint.useTls);
    const tokenOrNull = token?.trim() ? token.trim() : null;
    const passwordOrNull = password?.trim() ? password.trim() : null;
    const tlsCertPath = await this.resolveGatewayTlsCertPath(endpoint, endpointStableId);
    if (endpoint.useTls && tlsCertPath === null && this.pendingGatewayTrust !== null) {
      return;
    }

    const operatorOpts = await this.buildOperatorConnectOptions();
    const nodeOpts = await this.buildNodeConnectOptions();

    const remoteAddress =
      endpoint.host.includes(":") ? `[${endpoint.host}]:${endpoint.port}` : `${endpoint.host}:${endpoint.port}`;

    const operatorSession = new GatewaySession(
      this.identityStore,
      this.deviceAuthStore,
      (serverName, _remote, sessionKey) => {
        this.operatorConnected = true;
        this.operatorStatusText = "Connected";
        this.gatewayServerName = this.normalizedSummaryText(serverName);
        this.gatewayMainSessionKey = this.normalizeMainSessionKey(sessionKey);
        this.chatController?.applyMainSessionKey(this.resolveMainSessionKey());
        this._remoteAddress = remoteAddress;
        this.updateStatus();
        if (this.operatorConnected && this.nodeConnected) {
          this.resetCanvasRehydrateState();
          this.showLocalCanvasOnConnect();
          this.chatController?.applyMainSessionKey(this.resolveMainSessionKey());
          this.chatController?.bootstrap();
        }
        void this.refreshVoiceWakeWordsFromGateway();
        void this.refreshHomeCanvasOverviewIfConnected();
      },
      (message) => {
        this.operatorConnected = false;
        this.operatorStatusText = message;
        this.gatewayServerName = null;
        this._remoteAddress = "";
        this.chatController?.applyMainSessionKey(this.resolveMainSessionKey());
        this.updateStatus();
        this.chatController?.onDisconnected(message);
      },
      (event, payloadJson) => {
        if (event === "voicewake.changed") {
          const triggers = this.parseVoiceWakePayload(payloadJson);
          if (triggers) {
            void this.applyVoiceWakeWords(triggers, false).then(() => {
              void this.syncVoiceWakeState();
            });
          }
        }
        this.chatController?.handleGatewayEvent(event, payloadJson);
        this.voiceCoordinator.handleGatewayEvent(event, payloadJson);
      },
      null,
      null,
    );

    const nodeSession = new GatewaySession(
      this.identityStore,
      this.deviceAuthStore,
      () => {
        this.nodeConnected = true;
        this.nodeStatusText = "Connected";
        this.updateStatus();
        this.showLocalCanvasOnConnect();
        if (this.operatorConnected && this.nodeConnected) {
          this.resetCanvasRehydrateState();
          this.chatController?.applyMainSessionKey(this.resolveMainSessionKey());
          this.chatController?.bootstrap();
          void this.refreshHomeCanvasOverviewIfConnected();
        }
      },
      (message) => {
        this.nodeConnected = false;
        this.nodeStatusText = message;
        this.resetCanvasRehydrateState();
        this.showLocalCanvasOnDisconnect();
        this.updateStatus();
      },
      () => {},
      async (req) => {
        const dispatcher = new InvokeDispatcher(
          new DeviceHandler(this.context),
          new SystemHandler(),
          new CameraHandler(
            this.context,
            () => this.foregroundActive,
            (message: string, kind: CameraHudKind, autoHideMs: number | null) => {
              this.showCameraHud(message, kind, autoHideMs);
            },
            () => {
              this.triggerCameraFlash();
            },
          ),
          new CalendarHandler(this.context),
          new ContactsHandler(this.context),
          new PhotosHandler(this.context),
          new LocationHandler(
            this.context,
            () => this.foregroundActive,
            () => this.getLocationPreciseEnabledSync(),
          ),
          new MotionHandler(this.context),
          new NotificationsHandler(this.context),
          () => this.getCameraEnabledSync(),
          () => this.getLocationModeSync() !== LocationMode.Off,
          this.makeCanvasInvokeHandler(),
        );
        return dispatcher.handleInvoke(req);
      },
      null,
    );

    this.operatorSession = operatorSession;
    this.nodeSession = nodeSession;
    this.chatController = new ChatController(operatorSession);
    this.chatController.setListener(null);

    try {
      await Promise.all([
        operatorSession.connect(endpoint, tokenOrNull, passwordOrNull, operatorOpts, tlsCertPath),
        nodeSession.connect(endpoint, tokenOrNull, passwordOrNull, nodeOpts, tlsCertPath),
      ]);
      await this.setManualEnabled(true);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.operatorConnected = false;
      this.nodeConnected = false;
      this.operatorStatusText = msg.startsWith("Gateway ") ? msg : `Gateway error: ${msg}`;
      this.nodeStatusText = "Offline";
      this.clearHomeCanvasOverview();
      this.resetCanvasRehydrateState();
      this.canvasWebHost.navigate("");
      this.updateStatus();
      const op = this.operatorSession;
      const node = this.nodeSession;
      this.operatorSession = null;
      this.nodeSession = null;
      this.chatController = null;
      op?.disconnect();
      node?.disconnect();
      throw new Error(msg);
    }
  }

  async acceptGatewayTrustPrompt(): Promise<void> {
    const prompt = this.pendingGatewayTrust;
    if (!prompt) {
      return;
    }
    await storeFingerprint(this.prefs, prompt.stableId, prompt.fingerprintSha256);
    writeTrustedCertPem(this.context, prompt.stableId, prompt.certPem);
    this.pendingGatewayTrust = null;
    this.notifyGatewayTrust();
    await this.connect(prompt.host, prompt.port, prompt.useTls, await this.getGatewayToken(), await this.getGatewayPassword(), prompt.stableId);
  }

  declineGatewayTrustPrompt(): void {
    this.pendingGatewayTrust = null;
    this.notifyGatewayTrust();
    this.operatorConnected = false;
    this.nodeConnected = false;
    this.operatorStatusText = "Offline";
    this.nodeStatusText = "Offline";
    this.updateStatus();
  }

  private async buildClientInfo(mode: string): Promise<GatewayClientInfo> {
    const modelIdentifier =
      [deviceInfo.manufacture, deviceInfo.productModel]
        .filter((s) => (s ?? "").trim().length > 0)
        .join(" ")
        .trim() || undefined;
    const stored = await this.prefs.getString("display.name");
    const fallback = (deviceInfo.marketName ?? deviceInfo.productModel ?? "").trim();
    const displayName = (stored?.trim() || fallback) || undefined;
    return {
      id: CLIENT_ID,
      version: VERSION,
      // Gateway command policy currently recognizes the mobile app as the Android client id.
      // Keep platform metadata Android-compatible until the gateway adds a Harmony-specific lane.
      platform: "android",
      mode,
      deviceFamily: "Android",
      displayName,
      modelIdentifier,
    };
  }

  private async buildNodeConnectOptions(): Promise<GatewayConnectOptions> {
    const motionActivityAvailable = MotionHandler.isActivityAvailable();
    const motionPedometerAvailable = MotionHandler.isPedometerAvailable();
    const motionAvailable = motionActivityAvailable || motionPedometerAvailable;
    const cameraEnabled = await this.getCameraEnabled();
    const locationMode = await this.getLocationMode();
    const voiceWakeMode = this.effectiveVoiceWakeMode(await this.getVoiceWakeMode());
    const locationEnabled = locationMode !== LocationMode.Off;
    const microphoneGranted = this.hasAnyPermission(["ohos.permission.MICROPHONE"]);
    const caps: string[] = [
      OpenClawCapability.Device,
      OpenClawCapability.System,
      OpenClawCapability.Canvas,
      OpenClawCapability.Calendar,
      OpenClawCapability.Contacts,
      OpenClawCapability.Photos,
      OpenClawCapability.Notifications,
    ];
    if (cameraEnabled) {
      caps.push(OpenClawCapability.Camera);
    }
    if (locationEnabled) {
      caps.push(OpenClawCapability.Location);
    }
    if (motionAvailable) {
      caps.push(OpenClawCapability.Motion);
    }
    if (voiceWakeMode !== VoiceWakeMode.Off && microphoneGranted) {
      caps.push(OpenClawCapability.VoiceWake);
    }
    const commands: string[] = [
      OpenClawDeviceCommand.Status,
      OpenClawDeviceCommand.Info,
      OpenClawDeviceCommand.Permissions,
      OpenClawDeviceCommand.Health,
      OpenClawSystemCommand.Notify,
      OpenClawCalendarCommand.Events,
      OpenClawCalendarCommand.Add,
      OpenClawContactsCommand.Search,
      OpenClawContactsCommand.Add,
      OpenClawPhotosCommand.Latest,
      OpenClawNotificationsCommand.List,
      OpenClawCanvasCommand.Present,
      OpenClawCanvasCommand.Hide,
      OpenClawCanvasCommand.Navigate,
      OpenClawCanvasCommand.Eval,
      OpenClawCanvasCommand.Snapshot,
      OpenClawCanvasA2UICommand.Push,
      OpenClawCanvasA2UICommand.PushJSONL,
      OpenClawCanvasA2UICommand.Reset,
    ];
    if (cameraEnabled) {
      commands.push(
        OpenClawCameraCommand.List,
        OpenClawCameraCommand.Snap,
        OpenClawCameraCommand.Clip,
      );
    }
    if (locationEnabled) {
      commands.push(OpenClawLocationCommand.Get);
    }
    if (motionActivityAvailable) {
      commands.push(OpenClawMotionCommand.Activity);
    }
    if (motionPedometerAvailable) {
      commands.push(OpenClawMotionCommand.Pedometer);
    }
    const permissions: NodePermissionsShape = {
      camera: cameraEnabled && this.hasAnyPermission(["ohos.permission.CAMERA"]),
      location: locationEnabled && this.hasAnyPermission([
        "ohos.permission.APPROXIMATELY_LOCATION",
        "ohos.permission.LOCATION",
      ]),
      microphone: microphoneGranted,
    };
    return {
      role: "node",
      scopes: [],
      caps,
      commands,
      permissions,
      client: await this.buildClientInfo("node"),
      userAgent: `OpenClawHarmonyOS/${VERSION} (HarmonyOS; ArkTS)`,
    };
  }

  private async buildOperatorConnectOptions(): Promise<GatewayConnectOptions> {
    return {
      role: "operator",
      scopes: ["operator.read", "operator.write", "operator.talk.secrets"],
      caps: [],
      commands: [],
      permissions: {},
      client: await this.buildClientInfo("ui"),
      userAgent: `OpenClawHarmonyOS/${VERSION} (HarmonyOS; ArkTS)`,
    };
  }

  async refreshGatewayConnection(): Promise<void> {
    const host = await this.getManualHost();
    const portStr = await this.getManualPort();
    const port = parseInt(portStr, 10) || 18789;
    const useTls = await this.getManualTls();
    const token = await this.getGatewayToken();
    const password = await this.getGatewayPassword();
    if (!host || host.trim().length === 0) {
      this.operatorConnected = false;
      this.nodeConnected = false;
      this.operatorStatusText = "Failed: no cached gateway endpoint";
      this.nodeStatusText = "Offline";
      this.updateStatus();
      return;
    }
    await this.connect(host.trim(), port, useTls, token, password);
  }

  /**
   * HarmonyOS may tear down WebSockets when the app backgrounds; reconnect when returning to foreground.
   * Only runs if the user had a successful manual gateway connection (see connect() -> setManualEnabled(true)).
   */
  async reconnectGatewayOnForeground(): Promise<void> {
    const enabled = await this.getManualEnabled();
    if (!enabled) {
      return;
    }
    await this.refreshGatewayConnection();
  }

  disconnect(): void {
    void this.voiceCoordinator.prepareDisconnect();
    void this.voiceWakeManager.stop("Offline");
    this.resetNotificationForwardingBaseline();
    this.pendingGatewayTrust = null;
    this.notifyGatewayTrust();
    if (this.operatorSession) {
      this.operatorSession.disconnect();
      this.operatorSession = null;
    }
    if (this.nodeSession) {
      this.nodeSession.disconnect();
      this.nodeSession = null;
    }
    this.chatController = null;
    this.operatorConnected = false;
    this.nodeConnected = false;
    this.operatorStatusText = "Offline";
    this.nodeStatusText = "Offline";
    this._remoteAddress = "";
    this.clearHomeCanvasOverview();
    this.resetCanvasRehydrateState();
    this.updateHomeCanvasState();
    this.canvasWebHost.navigate("");
    this.updateStatus();
  }

  async clearPairing(): Promise<void> {
    this.disconnect();
    await this.prefs.clear();
    this.identityStore.clearCache();
  }

  async saveManualConfig(
    host: string,
    port: number,
    tls: boolean,
    token: string,
    password: string,
  ): Promise<void> {
    await this.prefs.putString("manual.host", host.trim());
    await this.prefs.putString("manual.port", String(port));
    await this.prefs.putBoolean("manual.tls", tls);
    await this.prefs.putString("gateway.token", token.trim());
    await this.prefs.putString("gateway.password", password.trim());
  }

  async setManualEnabled(enabled: boolean): Promise<void> {
    await this.prefs.putBoolean("manual.enabled", enabled);
  }

  async getManualEnabled(): Promise<boolean> {
    return await this.prefs.getBoolean("manual.enabled");
  }

  async getManualHost(): Promise<string> {
    return (await this.prefs.getString("manual.host")) ?? "10.0.2.2";
  }

  async getManualPort(): Promise<string> {
    return (await this.prefs.getString("manual.port")) ?? "18789";
  }

  async getManualTls(): Promise<boolean> {
    return await this.prefs.getBoolean("manual.tls");
  }

  async getGatewayToken(): Promise<string> {
    return (await this.prefs.getString("gateway.token")) ?? "";
  }

  async getGatewayPassword(): Promise<string> {
    return (await this.prefs.getString("gateway.password")) ?? "";
  }
}
