# Scrobbled AT - Technical Specification

## Overview

Federated music sharing platform built on AT Protocol. Users explicitly share tracks with context (comments/tags), follow others, and discover music through human curation.

## Core Principles

1. **Explicit over passive** - Users manually share tracks, not automatic scrobbling
2. **Human curation** - No algorithmic recommendations, only people you follow
3. **Cross-platform** - Works with Spotify, Apple Music, YouTube Music
4. **Federated** - Built on AT Protocol, users own their data
5. **Thin client** - Heavy lifting happens server-side

## System Architecture

### AT Protocol Lexicon

**app.scrobbled.share** - Music share record

```typescript
{
  $type: "app.scrobbled.share",
  track: {
    url: string,           // spotify:track:xxx or https://music.apple.com/...
    title: string,
    artist: string,
    album?: string,
    isrc?: string          // International Standard Recording Code
  },
  comment?: string,        // User's thoughts on the track
  tags?: string[],         // ["chill", "workout", "sunday"]
  mood?: string,           // Optional mood descriptor
  createdAt: string        // ISO 8601 timestamp
}
```

### Components

#### 1. AppView Service

**Purpose**: Index music shares, normalize tracks, serve feeds

**Responsibilities**:
- Subscribe to AT Protocol firehose
- Filter for `app.scrobbled.share` records
- Store shares in DynamoDB
- Normalize track identities (find cross-platform URLs)
- Build and cache feeds
- Generate playlist data

**Tech Stack**:
- Runtime: Node.js on AWS Lambda
- Framework: Hono.js (lightweight, fast)
- Database: DynamoDB
- AT Protocol: @atproto/api

**API Endpoints**:

```
GET /feed
  Query params: userId (DID), limit, cursor
  Returns: Paginated feed of shares from followed users

GET /feed/filtered
  Query params: userId, tags[], users[], startDate, endDate
  Returns: Filtered feed

GET /playlist
  Query params: userId, tags[], users[]
  Returns: Ordered list of tracks for playlist creation

GET /track/:id
  Returns: Track metadata + cross-platform URLs

POST /normalize
  Body: { trackUrl }
  Returns: Normalized track with all platform URLs
  (Internal endpoint, called by background job)
```

**Database Schema** (DynamoDB):

**Table: MusicShares**
```
PK: SHARE#{postUri}
SK: TIMESTAMP#{createdAt}
Attributes:
  - postUri (AT Protocol URI)
  - userId (DID)
  - trackUrl (original URL)
  - normalizedTrackId (internal ID)
  - metadata (title, artist, album)
  - comment
  - tags[]
  - mood
  - createdAt
GSI1: userId-createdAt (for user's shares)
GSI2: normalizedTrackId (for track lookups)
```

**Table: TrackMappings**
```
PK: TRACK#{normalizedTrackId}
Attributes:
  - normalizedTrackId (ISRC or internal)
  - spotifyUrl
  - spotifyId
  - appleMusicUrl
  - appleMusicId
  - youtubeMusicUrl
  - youtubeMusicId
  - isrc
  - musicbrainzId
  - metadata (title, artist, album, artwork)
  - updatedAt
```

**Table: UserFollows** (Cache of AT Protocol follows)
```
PK: USER#{userId}
SK: FOLLOWS#{followingId}
Attributes:
  - followerId (DID)
  - followingId (DID)
  - createdAt
GSI1: followingId (for reverse lookups)
```

**Background Jobs**:

1. **Firehose Subscriber**
   - Connects to AT Protocol relay
   - Filters for `app.scrobbled.share` records
   - Writes to MusicShares table
   - Triggers track normalization

2. **Track Normalizer**
   - Processes new shares
   - Looks up track in Spotify/Apple/YouTube APIs
   - Extracts ISRC if available
   - Finds equivalent URLs on other platforms
   - Stores in TrackMappings table

3. **Follow Sync**
   - Periodically syncs user follows from AT Protocol
   - Updates UserFollows cache
   - Triggered on user login or manual refresh

#### 2. iOS App

**Tech**: Swift, SwiftUI, MusicKit

**Features**:
- Share Extension (receives shares from Music/Spotify apps)
- AT Protocol authentication
- Feed display with filtering
- Deep linking to music apps
- Playlist creation via MusicKit

**Key Views**:
- Feed (list of shares from followed users)
- Share composer (add comment/tags)
- Profile (user's shares)
- Filters (by user, tag, date)
- Playlist creator

**Share Extension Flow**:
1. User shares track from Spotify/Apple Music
2. Share sheet shows Scrobbled AT
3. Extension receives URL
4. Shows composer with track preview
5. User adds comment/tags
6. Posts to user's PDS via AT Protocol API
7. Confirmation + option to view in app

#### 3. Android App

**Tech**: Kotlin, Jetpack Compose, Media3

**Features**: Same as iOS

**Intent Filter**:
- Receives shares from Spotify, YouTube Music, etc.
- Handles music URLs

#### 4. Infrastructure (SST v3)

**Resources**:

```typescript
// API
const api = new sst.aws.Function("AppViewApi", {
  handler: "packages/appview/src/index.handler",
  url: true,
  environment: {
    SHARES_TABLE: sharesTable.name,
    TRACKS_TABLE: tracksTable.name,
    FOLLOWS_TABLE: followsTable.name,
  }
});

// DynamoDB Tables
const sharesTable = new sst.aws.Dynamo("MusicShares", {
  fields: {
    pk: "string",
    sk: "string",
    userId: "string",
    createdAt: "string",
    normalizedTrackId: "string",
  },
  primaryIndex: { hashKey: "pk", rangeKey: "sk" },
  globalIndexes: {
    userIndex: { hashKey: "userId", rangeKey: "createdAt" },
    trackIndex: { hashKey: "normalizedTrackId" },
  }
});

// Firehose Subscriber (long-running)
const subscriber = new sst.aws.Function("FirehoseSubscriber", {
  handler: "packages/appview/src/subscriber.handler",
  timeout: "15 minutes",
  memory: "512 MB",
});

// Track Normalizer (event-driven)
const normalizer = new sst.aws.Function("TrackNormalizer", {
  handler: "packages/appview/src/normalizer.handler",
  timeout: "30 seconds",
});
```

## Music Platform Integration

### Spotify

**API**: Web API
**Auth**: OAuth 2.0 (for playlist creation)
**Endpoints**:
- `/v1/tracks/{id}` - Get track metadata
- `/v1/search` - Search by ISRC
- `/v1/me/playlists` - Create playlist
- `/v1/playlists/{id}/tracks` - Add tracks

**Deep Link**: `spotify:track:{id}` or `https://open.spotify.com/track/{id}`

### Apple Music

**API**: MusicKit
**Auth**: Developer token + user token (for library access)
**Endpoints**:
- `/v1/catalog/{storefront}/songs/{id}` - Get track
- `/v1/catalog/{storefront}/songs?filter[isrc]={isrc}` - Search by ISRC
- `/v1/me/library/playlists` - Create playlist

**Deep Link**: `https://music.apple.com/us/song/{id}` or `music://`

### YouTube Music

**API**: YouTube Data API v3
**Auth**: OAuth 2.0
**Endpoints**:
- `/v3/videos` - Get video metadata
- `/v3/search` - Search
- `/v3/playlists` - Create playlist

**Deep Link**: `https://music.youtube.com/watch?v={id}`

### MusicBrainz (for ISRC lookups)

**API**: MusicBrainz API (open, no auth)
**Purpose**: Find ISRC, cross-reference tracks
**Endpoint**: `/ws/2/recording?isrc={isrc}`

## Data Flow Examples

### Share a Track

1. User shares `spotify:track:abc123` from Spotify app
2. iOS share extension receives URL
3. User adds comment: "Perfect Sunday morning vibe"
4. User adds tags: ["chill", "sunday"]
5. App posts to user's PDS:
   ```json
   {
     "$type": "app.scrobbled.share",
     "track": {
       "url": "spotify:track:abc123",
       "title": "Song Name",
       "artist": "Artist Name",
       "album": "Album Name"
     },
     "comment": "Perfect Sunday morning vibe",
     "tags": ["chill", "sunday"],
     "createdAt": "2026-03-01T10:00:00Z"
   }
   ```
6. AppView firehose subscriber sees new record
7. Stores in MusicShares table
8. Triggers track normalizer
9. Normalizer looks up track in Spotify API, gets ISRC
10. Searches Apple Music and YouTube by ISRC
11. Stores mappings in TrackMappings table

### View Feed

1. User opens app
2. App queries: `GET /feed?userId={did}&limit=50`
3. AppView:
   - Looks up user's follows from UserFollows cache
   - Queries MusicShares for shares from followed users
   - Joins with TrackMappings for cross-platform URLs
   - Returns paginated feed
4. App displays feed with track cards
5. Each card shows: artwork, title, artist, comment, tags, sharer
6. Tap track → shows options: "Open in Spotify", "Open in Apple Music", etc.

### Create Playlist

1. User applies filter: tag="workout", users=["sarah", "mike"]
2. Tap "Create Playlist"
3. App queries: `GET /playlist?userId={did}&tags=workout&users=sarah,mike`
4. AppView returns ordered list of tracks with platform URLs
5. User selects "Create in Spotify"
6. App calls Spotify API:
   - Creates playlist: "Workout Mix from Sarah & Mike"
   - Adds tracks
7. Deep links to Spotify to show new playlist

## Security & Privacy

- Users control who sees their shares (AT Protocol visibility)
- OAuth tokens stored locally in keychain/keystore
- AppView doesn't store music service credentials
- Rate limiting on API endpoints
- No tracking, no analytics (unless user opts in)

## Deployment

**Environments**:
- `dev` - Development (sandbox AT Protocol)
- `staging` - Staging (sandbox AT Protocol)
- `prod` - Production (live AT Protocol)

**CI/CD**:
- GitHub Actions
- Deploy on push to main (staging)
- Manual promotion to prod

**Monitoring**:
- CloudWatch for Lambda metrics
- Error tracking (Sentry)
- API metrics (latency, errors)

## Cost Estimates

**AWS (10k users, 100k shares/month)**:
- Lambda: ~$20/month
- DynamoDB: ~$30/month
- API Gateway: ~$10/month
- Data transfer: ~$10/month
- **Total: ~$70/month**

**Music APIs**:
- Spotify: Free (rate limited)
- Apple Music: Free (requires developer account)
- YouTube: Free (rate limited)
- MusicBrainz: Free

## Development Phases

### Phase 1: MVP (4-6 weeks)
- [ ] AT Protocol lexicon definition
- [ ] AppView basic implementation (firehose, storage)
- [ ] iOS app (share extension, feed display)
- [ ] Basic track normalization (Spotify only)
- [ ] SST infrastructure

### Phase 2: Cross-Platform (2-3 weeks)
- [ ] Apple Music integration
- [ ] YouTube Music integration
- [ ] ISRC-based track matching
- [ ] Android app

### Phase 3: Playlists (2 weeks)
- [ ] Playlist generation API
- [ ] Spotify playlist creation
- [ ] Apple Music playlist creation
- [ ] Smart filters

### Phase 4: Polish (ongoing)
- [ ] Performance optimization
- [ ] Caching improvements
- [ ] UI/UX refinements
- [ ] Analytics (optional)

## Open Questions

1. Should we support SoundCloud? Bandcamp?
2. How to handle tracks not available on all platforms?
3. Should we cache artwork? Or always fetch from music services?
4. Do we need real-time updates (WebSocket) or is polling sufficient?
5. Should users be able to "like" or comment on others' shares?
