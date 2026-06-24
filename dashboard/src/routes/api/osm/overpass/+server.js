import { json } from '@sveltejs/kit';

const OVERPASS_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter'
];

const MAX_TILES = 64;
const TARGET_TILE_DEGREES = 0.08;

function parseBbox(value) {
  const parts = String(value ?? '').split(',').map(Number);
  if (parts.length !== 4 || parts.some((v) => !Number.isFinite(v))) {
    throw new Error('bbox muss vier Zahlen enthalten: south,west,north,east.');
  }

  const [s, w, n, e] = parts;
  if (s < -90 || n > 90 || w < -180 || e > 180 || s >= n || w >= e) {
    throw new Error('bbox liegt ausserhalb gueltiger Koordinaten.');
  }

  return [s, w, n, e];
}

function splitBbox(bbox) {
  const [s, w, n, e] = bbox;
  const latSpan = n - s;
  const lonSpan = e - w;
  let rows = Math.max(1, Math.ceil(latSpan / TARGET_TILE_DEGREES));
  let cols = Math.max(1, Math.ceil(lonSpan / TARGET_TILE_DEGREES));

  if (rows * cols > MAX_TILES) {
    const scale = Math.sqrt((rows * cols) / MAX_TILES);
    rows = Math.max(1, Math.ceil(rows / scale));
    cols = Math.max(1, Math.ceil(cols / scale));
  }

  const tiles = [];
  for (let row = 0; row < rows; row++) {
    const ts = s + (latSpan * row) / rows;
    const tn = s + (latSpan * (row + 1)) / rows;
    for (let col = 0; col < cols; col++) {
      const tw = w + (lonSpan * col) / cols;
      const te = w + (lonSpan * (col + 1)) / cols;
      tiles.push([ts, tw, tn, te]);
    }
  }
  return tiles;
}

function buildQuery([s, w, n, e]) {
  return `[out:json][timeout:30];
way["highway"](${s},${w},${n},${e});
out geom;`;
}

async function queryTile(serverFetch, tile) {
  const query = buildQuery(tile);
  const body = new URLSearchParams({ data: query }).toString();
  const errors = [];

  for (const endpoint of OVERPASS_ENDPOINTS) {
    try {
      const res = await serverFetch(endpoint, {
        method: 'POST',
        headers: {
          accept: 'application/json',
          'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'user-agent': 'SurfaceSense Dashboard/1.0'
        },
        body
      });
      const text = await res.text();
      if (res.ok) return JSON.parse(text).elements ?? [];
      errors.push(`${new URL(endpoint).hostname}: ${res.status} ${text.slice(0, 180)}`);
    } catch (err) {
      errors.push(`${new URL(endpoint).hostname}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  throw new Error(errors.join(' | '));
}

/**
 * POST /api/osm/overpass
 * Body: { query: string }  — raw Overpass QL (used by the around: strategy)
 * Relays the query to Overpass endpoints with automatic failover.
 */
export async function POST({ request, fetch }) {
  let query;
  try {
    const body = await request.json();
    query = body?.query;
    if (!query || typeof query !== 'string') throw new Error('Kein gültiger Query im Body.');
  } catch (err) {
    return json({ message: err instanceof Error ? err.message : String(err) }, { status: 400 });
  }

  const formBody = new URLSearchParams({ data: query }).toString();
  const errors = [];

  for (const endpoint of OVERPASS_ENDPOINTS) {
    try {
      const res = await fetch(endpoint, {
        method: 'POST',
        headers: {
          accept: 'application/json',
          'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'user-agent': 'SurfaceSense Dashboard/1.0',
        },
        body: formBody,
      });
      const text = await res.text();
      if (res.ok) {
        return json(
          { elements: JSON.parse(text).elements ?? [] },
          { headers: { 'cache-control': 'public, max-age=3600' } },
        );
      }
      errors.push(`${new URL(endpoint).hostname}: ${res.status} ${text.slice(0, 180)}`);
    } catch (err) {
      errors.push(`${new URL(endpoint).hostname}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  return json({ message: `Overpass nicht erreichbar: ${errors.join(' | ')}` }, { status: 502 });
}

export async function GET({ url, fetch }) {
  let bbox;
  try {
    bbox = parseBbox(url.searchParams.get('bbox'));
  } catch (err) {
    return json({ message: err instanceof Error ? err.message : String(err) }, { status: 400 });
  }

  const tiles = splitBbox(bbox);
  const elementsById = new Map();

  try {
    for (const tile of tiles) {
      const elements = await queryTile(fetch, tile);
      for (const element of elements) {
        elementsById.set(`${element.type}:${element.id}`, element);
      }
    }

    return json(
      { elements: Array.from(elementsById.values()) },
      { headers: { 'cache-control': 'public, max-age=3600' } }
    );
  } catch (err) {
    return json(
      {
        message: `Overpass API nicht erreichbar oder Anfrage abgelehnt (${tiles.length} Kacheln): ${
          err instanceof Error ? err.message : String(err)
        }`
      },
      { status: 502 }
    );
  }
}
