# Melete

English | [日本語](README.ja.md)

Melete is a macOS app for recording strength workouts and other exercise sessions. It lets you define exercises and the numeric values tracked for each one, then review workout history by date.

## Features

- Create, rename, archive, and restore exercises.
- Define numeric exercise metrics with units, integer or decimal input (up to three decimal places), and required or optional values. Metrics can be enabled or hidden from future entry forms.
- Record multiple exercises and sets on a date, with separate values per set; review, edit, and delete workouts, exercise records, or sets in the calendar-based history.
- Store ordinary workout and exercise data locally with SwiftData. There is no app feature for cloud sync, backup, export, or import.

The chat screen is a fixed scripted demo: it ignores the text you enter, performs no network requests or AI inference, and uses an in-memory store separate from your workout data. Real ChatGPT sign-in and AI inference are unavailable. OAuth and Responses API-related code is not integrated into the chat flow. V2 data handling is experimental and intended for isolated validation, not ordinary use with the app's real data.

Goals, analytics, notifications, and synchronization are not implemented.

## Requirements and build

- macOS 14.0 or later (the deployment target in `project.yml`).
- Xcode with the macOS SDK.
- XcodeGen to regenerate the Xcode project when needed.

The tracked `Melete.xcodeproj` can be used to build the app with Xcode. Its project definition is `project.yml`; when that definition changes, regenerate the project with XcodeGen rather than editing the generated project by hand:

```sh
xcodegen generate
```

Build the app using the `Melete` scheme:

```sh
xcodebuild -project Melete.xcodeproj -scheme Melete build
```

The project uses Swift Package Manager dependencies declared in `project.yml`: JOSESwift 3.0.0 and SwiftNIO 2.105.0. Xcode resolves these packages as part of project setup/build.

Building verifies compilation; it does not run the app or validate its behavior against existing real-user data. Running the normal `Melete` app uses its ordinary local SwiftData store. For safe test procedures and isolated-store requirements, consult [AGENTS.md](AGENTS.md); do not use unrestricted tests against real data.

## Data and limitations

Workout and exercise data is stored locally using SwiftData. The normal app configuration is V1. The experimental V2 route is for isolated validation and should not be treated as a supported migration or ordinary real-data execution path. The app has no backup or recovery feature, so a successful build does not establish that existing data is safe to open, modify, or migrate.

See [AGENTS.md](AGENTS.md) for repository-specific build and isolated-testing guidance.
