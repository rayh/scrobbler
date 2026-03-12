import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { getUserProfile } from '../api'
import type { UserProfile } from '../types'
import styles from './UserPage.module.css'

const APP_STORE_URL = 'https://apps.apple.com/app/selector/id0000000000'

function buildDeepLink(handle: string) {
  return `slctr://profile/${handle}`
}

export default function UserPage() {
  const { handle } = useParams<{ handle: string }>()
  const [profile, setProfile] = useState<UserProfile | null>(null)
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound] = useState(false)

  useEffect(() => {
    if (!handle) return

    // Persist the handle so the app can auto-follow after install/login
    try {
      localStorage.setItem('pendingFollowHandle', handle)
    } catch {
      // private browsing / storage blocked — ignore
    }

    getUserProfile(handle)
      .then(setProfile)
      .catch(() => setNotFound(true))
      .finally(() => setLoading(false))
  }, [handle])

  // Attempt immediate deep link on iOS — if the app is installed it will open;
  // if not, nothing happens (we don't want to interrupt the page load)
  useEffect(() => {
    if (!handle) return
    const isMobile = /iPhone|iPad|iPod/.test(navigator.userAgent)
    if (!isMobile) return
    const timer = setTimeout(() => {
      window.location.href = buildDeepLink(handle)
    }, 600)
    return () => clearTimeout(timer)
  }, [handle])

  const displayName = profile?.name || handle || ''
  const initial = displayName[0]?.toUpperCase() || '?'

  return (
    <div className={styles.page}>
      <div className={styles.card}>
        {loading && (
          <div className={styles.skeletonAvatar} />
        )}

        {!loading && (
          <>
            {profile?.avatarUrl ? (
              <img
                className={styles.avatar}
                src={profile.avatarUrl}
                alt={displayName}
              />
            ) : (
              <div className={styles.avatarPlaceholder}>
                {initial}
              </div>
            )}

            {notFound ? (
              <>
                <h1 className={styles.name}>@{handle}</h1>
                <p className={styles.sub}>User not found</p>
              </>
            ) : (
              <>
                <h1 className={styles.name}>{displayName}</h1>
                <p className={styles.handle}>@{handle}</p>
                {profile && (
                  <p className={styles.stats}>
                    <span>{profile.followersCount} followers</span>
                    <span className={styles.dot}>·</span>
                    <span>{profile.posts.length} shares</span>
                  </p>
                )}
              </>
            )}
          </>
        )}

        {!notFound && (
          <a
            className={styles.openBtn}
            href={buildDeepLink(handle ?? '')}
          >
            Open in Selector
          </a>
        )}

        <a className={styles.downloadLink} href={APP_STORE_URL}>
          Don't have the app? Download it free →
        </a>
      </div>

      <a href="/" className={styles.logo}>
        Selector
      </a>
    </div>
  )
}
