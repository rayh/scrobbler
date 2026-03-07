# Scrobbled AT - UX & Design Spec

## Core User Flows

### 1. Share a Track

**Entry Points:**
- Spotify app → Share → Scrobbled AT
- Apple Music app → Share → Scrobbled AT
- YouTube Music app → Share → Scrobbled AT

**Flow:**
1. User taps share in music app
2. Selects "Scrobbled AT" from share sheet
3. Share composer opens with:
   - Track preview (artwork, title, artist)
   - Comment field (optional, 500 chars)
   - Tag input (chips, suggestions: chill, workout, focus, party, etc.)
   - Mood selector (optional: happy, sad, energetic, calm)
   - Post button
4. User adds context, taps Post
5. Success confirmation with options:
   - View in feed
   - Share another
   - Close

**Design Notes:**
- Fast and lightweight - should feel instant
- Comment field is prominent but optional
- Tag suggestions based on time of day, previous tags
- Artwork is large and prominent

### 2. View Feed

**Main Feed View:**
- Vertical scroll of track cards
- Each card shows:
  - Track artwork (square, large)
  - Title, artist, album (truncated)
  - Sharer's name and avatar
  - Comment (if present)
  - Tags (chips)
  - Timestamp (relative: "2h ago")
  - Action buttons: Play, More

**Interactions:**
- Tap card → Track detail view
- Tap artwork → Play in preferred app (shows picker first time)
- Tap sharer → View their profile
- Tap tag → Filter by tag
- Pull to refresh
- Infinite scroll

**Filter Bar (top):**
- All (default)
- By user (multi-select)
- By tag (multi-select)
- By date range
- Active filters shown as removable chips

**Design Notes:**
- Clean, music-focused design
- Artwork is hero element
- Comments are readable without tapping
- Fast scrolling performance

### 3. Track Detail

**View:**
- Large artwork (full width)
- Title, artist, album
- Sharer info (avatar, name, timestamp)
- Full comment
- Tags
- "Open in..." section:
  - Spotify button
  - Apple Music button
  - YouTube Music button
  - (Grayed out if not available)
- Related shares (other people who shared this track)

**Actions:**
- Open in [platform]
- Add to playlist
- Share (native share sheet)
- Report (if needed)

### 4. Create Playlist

**Entry Point:**
- Filter feed → Tap "Create Playlist" button (floating action button)

**Flow:**
1. Shows filtered tracks count: "23 tracks from Sarah & Mike tagged #workout"
2. Platform selector:
   - Spotify
   - Apple Music
   - YouTube Music
3. Playlist name (pre-filled, editable)
4. Tap "Create"
5. Progress indicator
6. Success → "Open in Spotify" button

**Design Notes:**
- Quick and obvious
- Shows preview of what will be created
- Handles missing tracks gracefully (shows count)

### 5. Profile

**Own Profile:**
- Avatar, name, handle
- Stats: X shares, Y followers, Z following
- Recent shares (grid or list)
- Settings button

**Other User's Profile:**
- Same layout
- Follow/Unfollow button
- Filter feed to this user

### 6. Onboarding

**First Launch:**
1. Welcome screen
   - "Share music with people, not algorithms"
   - Continue button
2. Sign in with Bluesky
   - AT Protocol authentication
   - Handle/password
3. Music preferences
   - "Which apps do you use?"
   - Checkboxes: Spotify, Apple Music, YouTube Music
   - Sets default for opening tracks
4. Find people
   - Import from Bluesky follows
   - Suggested users (optional)
5. Done → Feed

## Visual Design

### Style

**Aesthetic:**
- Clean, modern, music-first
- Dark mode by default (light mode available)
- Emphasis on album artwork
- Minimal chrome

**Colors:**
- Primary: Deep purple (#6B46C1)
- Accent: Bright cyan (#00D9FF)
- Background: True black (#000000) / White (#FFFFFF)
- Surface: Dark gray (#1A1A1A) / Light gray (#F5F5F5)
- Text: White / Black with appropriate contrast

**Typography:**
- Headings: SF Pro Display (iOS) / Roboto (Android) - Bold
- Body: SF Pro Text / Roboto - Regular
- Track titles: Medium weight
- Comments: Regular weight

**Spacing:**
- Generous padding around cards
- Consistent 16px base unit
- Breathing room for artwork

### Components

**Track Card:**
```
┌─────────────────────────────────┐
│  ┌────────┐                     │
│  │        │  Track Title        │
│  │ Art    │  Artist Name        │
│  │        │  @sharer · 2h ago   │
│  └────────┘                     │
│                                 │
│  "This is perfect for Sunday    │
│   morning coffee..."            │
│                                 │
│  [chill] [sunday] [coffee]      │
│                                 │
│  [▶ Play]           [⋯ More]    │
└─────────────────────────────────┘
```

**Filter Chips:**
- Rounded pills
- Outlined when inactive
- Filled when active
- X to remove

**Buttons:**
- Primary: Filled, rounded
- Secondary: Outlined, rounded
- Icon buttons: Circular, subtle background

## Interactions

**Gestures:**
- Swipe left on card → Quick actions (add to playlist, share)
- Long press on card → Preview track (if possible)
- Pull down → Refresh
- Swipe between tabs (Feed, Profile, Search)

**Animations:**
- Smooth transitions between views
- Cards fade in as they appear
- Artwork crossfades when changing
- Subtle spring animations for buttons

**Haptics:**
- Light tap on button press
- Medium tap on successful action
- Error vibration on failure

## Empty States

**No Shares Yet:**
- Illustration of music notes
- "No shares yet"
- "Follow people to see their music shares"
- "Find people" button

**No Results:**
- "No tracks found"
- "Try different filters"
- "Clear filters" button

**Offline:**
- "You're offline"
- "Showing cached content"
- Retry button

## Error Handling

**Failed to Post:**
- Toast: "Failed to share track"
- Retry button
- Save draft locally

**Failed to Load Feed:**
- Error message in feed
- Retry button
- Show cached content if available

**Track Not Available:**
- Gray out platform button
- Show "Not available on [platform]"

## Accessibility

- VoiceOver/TalkBack support
- Dynamic type support
- High contrast mode
- Reduced motion option
- Keyboard navigation (iPad)

## Platform-Specific

**iOS:**
- Native share sheet integration
- MusicKit for Apple Music
- SF Symbols for icons
- SwiftUI animations

**Android:**
- Material Design 3
- Intent handling for shares
- Material You dynamic colors
- Predictive back gesture

## Performance

- Lazy loading of images
- Pagination (50 items per page)
- Cache artwork locally
- Prefetch next page
- Optimize for 60fps scrolling

## Future Considerations

- Collaborative playlists
- Comments on shares
- Likes/reactions
- Discovery feed (beyond follows)
- Weekly/monthly recaps
- Push notifications for new shares
