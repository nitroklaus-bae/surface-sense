import { derived, get, writable } from 'svelte/store';
import { fetchRides, supabase } from '$lib/supabase.js';
import { parseFIT, trackFromSurfaceSamples } from '$lib/rollex/trackParser';

const STORAGE_KEY = 'surface_sense_selected_ride_id';
const trackCache = new Map();

function storedRideId() {
  if (typeof localStorage === 'undefined') return '';
  return localStorage.getItem(STORAGE_KEY) ?? '';
}

function persistRideId(id) {
  if (typeof localStorage === 'undefined') return;
  if (id) localStorage.setItem(STORAGE_KEY, id);
  else localStorage.removeItem(STORAGE_KEY);
}

export const rideSelection = writable({
  rides: [],
  selectedRideId: '',
  admin: false,
  loading: false,
  loaded: false,
  error: '',
});

export const selectedRide = derived(rideSelection, ($selection) =>
  $selection.rides.find((ride) => ride.id === $selection.selectedRideId) ?? null
);

export async function loadCentralRides({ force = false } = {}) {
  const current = get(rideSelection);
  if (current.loading || (current.loaded && !force)) return current;

  rideSelection.update((state) => ({ ...state, loading: true, error: '' }));
  try {
    const result = await fetchRides();
    const rides = result.rides ?? [];
    let selectedRideId = current.selectedRideId || storedRideId();
    if (!rides.some((ride) => ride.id === selectedRideId)) {
      selectedRideId = rides[0]?.id ?? '';
    }
    persistRideId(selectedRideId);
    const next = {
      rides,
      selectedRideId,
      admin: result.admin,
      loading: false,
      loaded: true,
      error: '',
    };
    rideSelection.set(next);
    return next;
  } catch (error) {
    const message = error?.message ?? String(error);
    rideSelection.update((state) => ({
      ...state,
      loading: false,
      loaded: true,
      error: message,
    }));
    throw error;
  }
}

export function setSelectedRide(rideOrId) {
  const id = typeof rideOrId === 'string' ? rideOrId : (rideOrId?.id ?? '');
  persistRideId(id);
  rideSelection.update((state) => ({ ...state, selectedRideId: id }));
}

export function removeRideFromSelection(rideId) {
  for (const key of trackCache.keys()) {
    if (key.startsWith(`${rideId}:`)) trackCache.delete(key);
  }
  rideSelection.update((state) => {
    const rides = state.rides.filter((ride) => ride.id !== rideId);
    const selectedRideId = state.selectedRideId === rideId ? (rides[0]?.id ?? '') : state.selectedRideId;
    persistRideId(selectedRideId);
    return { ...state, rides, selectedRideId };
  });
}

export async function loadRideTrack(ride, { includeIri = true } = {}) {
  if (!ride) throw new Error('Keine zentrale Fahrt ausgewaehlt.');
  const cacheKey = `${ride.id}:${ride.fit_path ?? 'samples'}:${includeIri ? 'iri' : 'base'}`;
  if (trackCache.has(cacheKey)) return trackCache.get(cacheKey);

  if (ride.fit_path) {
    const { data: blob, error } = await supabase.storage.from('ride-files').download(ride.fit_path);
    if (!error && blob) {
      const track = parseFIT(await blob.arrayBuffer());
      trackCache.set(cacheKey, track);
      return track;
    }
  }

  const fields = includeIri
    ? 'ts_ms,lat,lon,speed_kmh,iri_m_km'
    : 'ts_ms,lat,lon,speed_kmh';
  const { data, error } = await supabase
    .from('surface_samples')
    .select(fields)
    .eq('ride_id', ride.id)
    .order('ts_ms');

  if (error) throw new Error('Surface-Samples: ' + error.message);
  const track = trackFromSurfaceSamples(data ?? []);
  trackCache.set(cacheKey, track);
  return track;
}
