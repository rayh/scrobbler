import type { Post } from '../types'
import styles from './PostCard.module.css'

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const s = Math.floor(diff / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h`
  return `${Math.floor(h / 24)}d`
}

interface Props {
  post: Post
  showUser?: boolean
  isNew?: boolean
}

export default function PostCard({ post, showUser = true, isNew = false }: Props) {
  const { track, userHandle, comment, createdAt, likes } = post

  return (
    <article className={`${styles.card} ${isNew ? styles.new : ''}`}>
      <div className={styles.artwork}>
        {track.artwork ? (
          <img src={track.artwork} alt={`${track.title} artwork`} />
        ) : (
          <div className={styles.artworkPlaceholder}>
            <span>♪</span>
          </div>
        )}
      </div>

      <div className={styles.body}>
        {showUser && (
          <div className={styles.user}>
            <span className={styles.handle}>@{userHandle}</span>
          </div>
        )}

        <div className={styles.track}>
          <span className={styles.title}>{track.title}</span>
          <span className={styles.artist}>{track.artist}</span>
          {track.album && <span className={styles.album}>{track.album}</span>}
        </div>

        {comment && <p className={styles.comment}>{comment}</p>}

        <div className={styles.meta}>
          <span className={styles.time}>{timeAgo(createdAt)}</span>
          {likes > 0 && <span className={styles.likes}>♥ {likes}</span>}
          {post.tags.length > 0 && (
            <span className={styles.tags}>
              {post.tags.map(t => `#${t}`).join(' ')}
            </span>
          )}
        </div>
      </div>

      {track.appleMusicUrl && (
        <a
          className={styles.playBtn}
          href={track.appleMusicUrl}
          target="_blank"
          rel="noopener noreferrer"
          aria-label="Open in Apple Music"
        >
          ▶
        </a>
      )}
    </article>
  )
}
