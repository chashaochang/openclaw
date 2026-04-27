export enum VoiceWakeMode {
  Off = 'off',
  Foreground = 'foreground',
  Always = 'always',
}

export function voiceWakeModeFromRaw(raw: string | undefined | null): VoiceWakeMode {
  const normalized = (raw ?? '').trim().toLowerCase();
  if (normalized === VoiceWakeMode.Off) {
    return VoiceWakeMode.Off;
  }
  if (normalized === VoiceWakeMode.Always) {
    return VoiceWakeMode.Always;
  }
  return VoiceWakeMode.Foreground;
}
