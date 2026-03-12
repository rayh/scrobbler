export interface Track {
  id: string
  title: string
  artist: string
  album?: string
  artwork?: string
  appleMusicUrl?: string
}

export interface Post {
  postId: string
  userId: string
  userHandle: string
  userName?: string
  track: Track
  comment?: string
  tags: string[]
  createdAt: string
  likes: number
}

export interface UserProfile {
  userId: string
  handle: string
  name?: string
  bio?: string
  avatarUrl?: string
  followersCount: number
  followingCount: number
  posts: Post[]
}

export interface FeedResponse {
  posts: Post[]
  cursor: string | null
}
