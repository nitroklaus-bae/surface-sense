// IndexedDB-backed cache for Overpass API responses.
// No practical quota limit (unlike localStorage's ~5 MB) and survives page reload.
const DB_NAME = 'tireoptimizer-osm'
const STORE = 'cache'
const DB_VERSION = 1
const MAX_ENTRIES = 500

interface CacheEntry { key: string; ts: number; data: unknown }

let _db: IDBDatabase | null = null

function openDb(): Promise<IDBDatabase> {
  if (_db) return Promise.resolve(_db)
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION)
    req.onupgradeneeded = (e) => {
      const db = (e.target as IDBOpenDBRequest).result
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'key' })
        store.createIndex('ts', 'ts', { unique: false })
      }
    }
    req.onsuccess = (e) => { _db = (e.target as IDBOpenDBRequest).result; resolve(_db) }
    req.onerror = () => reject(req.error)
  })
}

export async function osmCacheGet<T>(key: string): Promise<T | null> {
  try {
    const db = await openDb()
    return new Promise((resolve) => {
      const req = db.transaction(STORE, 'readonly').objectStore(STORE).get(key)
      req.onsuccess = () => resolve(req.result ? (req.result as CacheEntry).data as T : null)
      req.onerror = () => resolve(null)
    })
  } catch { return null }
}

export async function osmCacheSet(key: string, data: unknown): Promise<void> {
  try {
    const db = await openDb()
    const entry: CacheEntry = { key, ts: Date.now(), data }
    await new Promise<void>((resolve) => {
      const tx = db.transaction(STORE, 'readwrite')
      tx.objectStore(STORE).put(entry)
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
    })
    // Prune oldest entries when over cap
    await new Promise<void>((resolve) => {
      const tx = db.transaction(STORE, 'readwrite')
      const store = tx.objectStore(STORE)
      const req = store.index('ts').getAllKeys()
      req.onsuccess = () => {
        const keys = req.result as IDBValidKey[]
        if (keys.length > MAX_ENTRIES) {
          for (let i = 0; i < keys.length - MAX_ENTRIES; i++) store.delete(keys[i])
        }
      }
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
    })
  } catch { /* best-effort */ }
}
