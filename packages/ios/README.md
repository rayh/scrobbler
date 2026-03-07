# Scrobbled AT - iOS App

Native iOS app for sharing music tracks with comments and tags on AT Protocol.

## Features

- Share Extension for Music and Spotify apps
- AT Protocol authentication
- Feed of music shares from followed users
- Cross-platform deep linking
- Playlist creation

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Setup

1. Open `ScrobbledAT.xcodeproj` in Xcode
2. Configure signing & capabilities
3. Add MusicKit capability
4. Build and run

## Architecture

- SwiftUI for UI
- MusicKit for Apple Music integration
- AT Protocol Swift SDK for federation
- Share Extension for receiving shares

## Structure

```
ScrobbledAT/
├── App/
│   ├── ScrobbledATApp.swift
│   └── ContentView.swift
├── Features/
│   ├── Feed/
│   ├── Share/
│   └── Profile/
├── Services/
│   ├── ATProtocolService.swift
│   ├── MusicService.swift
│   └── APIService.swift
└── ShareExtension/
    └── ShareViewController.swift
```
