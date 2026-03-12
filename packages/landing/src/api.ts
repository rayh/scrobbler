// Injected by SST at build time; falls back to production API
const API = import.meta.env.VITE_API_URL
  ?? (typeof window !== 'undefined' && (window as unknown as Record<string, string>).SLCTR_API_URL)
  ?? 'https://api.slctr.io'

export const apiBase = API as string

export async function getPublicFeed(cursor?: string): Promise<{ posts: import('./types').Post[]; cursor: string | null }> {
  const url = new URL(`${apiBase}/feed/public`)
  if (cursor) url.searchParams.set('cursor', cursor)
  url.searchParams.set('limit', '20')
  const res = await fetch(url.toString())
  if (!res.ok) throw new Error(`Feed fetch failed: ${res.status}`)
  return res.json()
}

export async function getUserProfile(handle: string): Promise<import('./types').UserProfile> {
  const res = await fetch(`${apiBase}/users/${handle}`)
  if (!res.ok) throw new Error(`Profile fetch failed: ${res.status}`)
  return res.json()
}
