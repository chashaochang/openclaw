export enum LocationMode {
  Off = 'off',
  WhileUsing = 'whileUsing',
}

export function locationModeFromRaw(raw: string | null | undefined): LocationMode {
  const normalized = (raw ?? '').trim().toLowerCase();
  if (normalized === 'always') {
    return LocationMode.WhileUsing;
  }
  if (normalized === LocationMode.WhileUsing) {
    return LocationMode.WhileUsing;
  }
  return LocationMode.Off;
}
