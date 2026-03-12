import { useRef, useEffect } from 'react'
import PostCard from '../components/PostCard'
import { useFeed } from '../hooks/useFeed'
import styles from './HomePage.module.css'

const APP_STORE_URL = 'https://apps.apple.com/app/selector/id0000000000'

export default function HomePage() {
  const { posts, loading, loadingMore, error, cursor, newCount, loadMore, showNew } = useFeed()
  const bottomRef = useRef<HTMLDivElement>(null)

  // Infinite scroll via IntersectionObserver
  useEffect(() => {
    if (!bottomRef.current || !cursor) return
    const obs = new IntersectionObserver(
      entries => { if (entries[0].isIntersecting) loadMore() },
      { threshold: 0.1 }
    )
    obs.observe(bottomRef.current)
    return () => obs.disconnect()
  }, [cursor, loadMore])

  return (
    <div className={styles.page}>
      {/* Header */}
      <header className={styles.header}>
        <div className={styles.logo}>Selector</div>
        <a className={styles.downloadBtn} href={APP_STORE_URL}>
          Download
        </a>
      </header>

      {/* Hero */}
      <section className={styles.hero}>
        <h1 className={styles.heroTitle}>Share what you're playing</h1>
        <p className={styles.heroSub}>
          See what your friends and people nearby are listening to — in real time.
        </p>
        <div className={styles.downloadGroup}>
          <a className={styles.appStoreBadge} href={APP_STORE_URL}>
            <svg viewBox="0 0 120 40" fill="none" xmlns="http://www.w3.org/2000/svg" aria-label="Download on the App Store">
              <rect width="120" height="40" rx="7" fill="black" stroke="#aaa" strokeWidth="0.5"/>
              <text x="36" y="14" fill="white" fontSize="8" fontFamily="-apple-system,sans-serif">Download on the</text>
              <text x="28" y="28" fill="white" fontSize="13" fontWeight="600" fontFamily="-apple-system,sans-serif">App Store</text>
              <text x="10" y="26" fill="white" fontSize="22" fontFamily="-apple-system,sans-serif"></text>
            </svg>
          </a>
        </div>
      </section>

      {/* Live feed */}
      <section className={styles.feedSection}>
        <div className={styles.feedHeader}>
          <h2 className={styles.feedTitle}>
            <span className={styles.liveDot} />
            Live
          </h2>
          <p className={styles.feedSub}>What people are sharing right now</p>
        </div>

        {/* New posts banner */}
        {newCount > 0 && (
          <button className={styles.newBanner} onClick={showNew}>
            ↑ {newCount} new {newCount === 1 ? 'post' : 'posts'}
          </button>
        )}

        {loading && (
          <div className={styles.loadingGrid}>
            {[...Array(6)].map((_, i) => <div key={i} className={styles.skeleton} />)}
          </div>
        )}

        {error && (
          <p className={styles.error}>Could not load feed — {error}</p>
        )}

        {!loading && posts.length === 0 && !error && (
          <p className={styles.empty}>No shares yet — be the first!</p>
        )}

        <div className={styles.feedGrid}>
          {posts.map((post, i) => (
            <PostCard key={post.postId} post={post} isNew={i === 0 && newCount > 0} />
          ))}
        </div>

        {cursor && (
          <div ref={bottomRef} className={styles.loadMoreArea}>
            {loadingMore && <span className={styles.loadingText}>Loading more…</span>}
          </div>
        )}
      </section>

      {/* Footer CTA */}
      <footer className={styles.footer}>
        <p>Share your taste. Discover others.</p>
        <a className={styles.downloadBtn} href={APP_STORE_URL}>
          Get Selector →
        </a>
      </footer>
    </div>
  )
}
