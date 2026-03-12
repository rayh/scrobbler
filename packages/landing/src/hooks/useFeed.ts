import { useState, useEffect, useCallback, useRef } from 'react'
import type { Post } from '../types'
import { getPublicFeed } from '../api'

const POLL_INTERVAL = 15_000 // poll every 15s for new posts

export function useFeed() {
  const [posts, setPosts] = useState<Post[]>([])
  const [cursor, setCursor] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [newCount, setNewCount] = useState(0)
  const latestPostId = useRef<string | null>(null)

  const load = useCallback(async () => {
    try {
      setError(null)
      const data = await getPublicFeed()
      setPosts(data.posts)
      setCursor(data.cursor)
      if (data.posts.length > 0) {
        latestPostId.current = data.posts[0].postId
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load feed')
    } finally {
      setLoading(false)
    }
  }, [])

  const loadMore = useCallback(async () => {
    if (!cursor || loadingMore) return
    setLoadingMore(true)
    try {
      const data = await getPublicFeed(cursor)
      setPosts(prev => [...prev, ...data.posts])
      setCursor(data.cursor)
    } catch {
      // silently ignore load-more errors
    } finally {
      setLoadingMore(false)
    }
  }, [cursor, loadingMore])

  // Poll for new posts at the top
  const poll = useCallback(async () => {
    if (!latestPostId.current) return
    try {
      const data = await getPublicFeed()
      const currentLatest = latestPostId.current
      const newPosts = data.posts.filter(p => p.postId !== currentLatest && p.createdAt > (posts[0]?.createdAt ?? ''))
      if (newPosts.length > 0) {
        setNewCount(prev => prev + newPosts.length)
      }
    } catch {
      // ignore poll errors silently
    }
  }, [posts])

  const showNew = useCallback(() => {
    setNewCount(0)
    load()
  }, [load])

  useEffect(() => { load() }, [load])

  useEffect(() => {
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { posts, loading, loadingMore, error, cursor, newCount, loadMore, showNew }
}
