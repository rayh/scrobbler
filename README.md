# Scrobbled AT

Federated music sharing on AT Protocol. Share tracks with comments and tags, discover music through people you follow.

## Architecture

### Components

1. **Mobile Apps** (iOS/Android)
   - Native Swift/Kotlin
   - Share extension for music apps
   - Thin client - display and capture only

2. **AppView Service** (TypeScript)
   - Subscribes to AT Protocol firehose
   - Indexes music shares
   - Normalizes track identities across platforms
   - Serves feeds and playlists

3. **Infrastructure** (SST v3)
   - AWS Lambda for AppView
   - DynamoDB for data storage
   - API Gateway for REST endpoints

### Data Flow

```
User shares track → PDS (AT Protocol) → Firehose → AppView → Mobile App
                                            ↓
                                    Track Normalization
                                    (Spotify/Apple/YouTube)
```

## Project Structure

```
scrobbled-at/
├── packages/
│   ├── appview/          # AppView service (TypeScript)
│   ├── ios/              # iOS app (Swift)
│   └── android/          # Android app (Kotlin)
├── infra/                # SST v3 infrastructure
├── lexicon/              # AT Protocol lexicon definitions
└── sst.config.ts         # SST configuration
```

## Tech Stack

- **Infrastructure**: SST v3, AWS (Lambda, DynamoDB, API Gateway)
- **AppView**: TypeScript, Hono.js
- **iOS**: Swift, SwiftUI
- **Android**: Kotlin, Jetpack Compose
- **Protocol**: AT Protocol SDK
- **Music APIs**: Spotify Web API, Apple MusicKit, YouTube Music API

## Features

### MVP
- Share tracks from Spotify/Apple Music with comments and tags
- Follow users on AT Protocol
- View feed of followed users' shares
- Open tracks in any music app (cross-platform links)
- Create playlists from feeds

### Future
- Smart filters (by tag, mood, user)
- Track normalization across platforms
- Collaborative playlists
- Discovery feeds
