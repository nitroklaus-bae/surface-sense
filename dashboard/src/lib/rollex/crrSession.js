import { writable } from 'svelte/store';

export const crrSession = writable({
  source: 'supabase',
  activeTab: 'analyse',
  results: null,
  lastRideId: '',
  lastProfileKey: '',
  lastWeightsKey: '',
});

export function makeCrrProfileKey(profile) {
  return JSON.stringify({
    riderWeightKg: Number(profile?.riderWeightKg ?? 0),
    bikeWeightKg: Number(profile?.bikeWeightKg ?? 0),
    avgPowerW: Number(profile?.avgPowerW ?? 0),
    minTireWidthMm: Number(profile?.minTireWidthMm ?? 0),
    maxTireWidthMm: Number(profile?.maxTireWidthMm ?? 0),
    hasTubeless: !!profile?.hasTubeless,
    ambientTempCelsius: Number(profile?.ambientTempCelsius ?? 20),
    crrModel: profile?.crrModel ?? 'physical',
  });
}

export function makeCrrWeightsKey(weights) {
  return JSON.stringify({
    speed: Number(weights?.speed ?? 0),
    puncture: Number(weights?.puncture ?? 0),
    handling: Number(weights?.handling ?? 0),
  });
}
