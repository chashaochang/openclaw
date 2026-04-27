import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

export function gatewayStatusForDisplay(statusText: string): string {
  const trimmed = statusText.trim();
  return trimmed.length > 0 ? trimmed : 'Offline';
}

export function gatewayStatusHasDiagnostics(statusText: string): boolean {
  const lower = gatewayStatusForDisplay(statusText).toLowerCase();
  return lower !== 'offline' && !lower.includes('connecting');
}

export function gatewayStatusLooksLikePairing(statusText: string): boolean {
  const lower = gatewayStatusForDisplay(statusText).toLowerCase();
  return lower.includes('pair') || lower.includes('approve');
}

export function buildGatewayDiagnosticsReport(
  screen: string,
  version: string,
  device: string,
  gatewayAddress: string,
  statusText: string,
): string {
  const endpoint = gatewayAddress.trim().length > 0 ? gatewayAddress.trim() : 'unknown';
  const status = gatewayStatusForDisplay(statusText);
  return (
    'Help diagnose this OpenClaw HarmonyOS gateway connection failure.\n\n' +
    'Please:\n' +
    '- pick one route only: same machine, same LAN, Tailscale, or public URL\n' +
    '- classify this as pairing/auth, TLS trust, wrong advertised route, wrong address/port, or gateway down\n' +
    '- quote the exact app status/error below\n' +
    '- tell me whether `openclaw devices list` should show a pending pairing request\n' +
    '- if more signal is needed, ask for `openclaw qr --json`, `openclaw devices list`, and `openclaw nodes status`\n' +
    '- give the next exact command or tap\n\n' +
    'Debug info:\n' +
    `- screen: ${screen}\n` +
    `- app version: OpenClaw HarmonyOS ${version}\n` +
    `- device: ${device}\n` +
    `- gateway address: ${endpoint}\n` +
    `- status/error: ${status}\n`
  );
}

export async function copyGatewayDiagnosticsReport(
  report: string,
  toastText: string,
): Promise<void> {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, report);
  const sys = pasteboard.getSystemPasteboard();
  await sys.setData(data);
  await promptAction.showToast({ message: toastText });
}

export function resourceString(context: common.UIAbilityContext | undefined, res: Resource, fallback: string = ''): string {
  if (!context) {
    return fallback;
  }
  try {
    return context.resourceManager.getStringSync(res);
  } catch {
    return fallback;
  }
}
