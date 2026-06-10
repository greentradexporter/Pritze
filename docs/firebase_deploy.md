# trimtime Firebase setup

This app requires Firebase configuration. If Firebase cannot initialize, the app
shows a setup error instead of falling back to local demo data.

## Firebase project setup

1. Create a Firebase project for `trimtime`.
2. Add an Android app with package name `com.trimtime.app`.
3. Add an iOS app with bundle ID `com.trimtime.app`.
4. Enable Authentication providers:
   - Phone
   - Google
5. Create a Cloud Firestore database.
6. Run FlutterFire configuration from the repo root:

```bash
flutterfire configure --platforms=android,ios --android-package-name=com.trimtime.app --ios-bundle-id=com.trimtime.app
```

This should create the platform Firebase config and `lib/firebase_options.dart`.
If you use generated options, update `lib/services/firebase_bootstrap.dart` to call:

```dart
await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
```

## Firestore collections

The app uses these top-level collections:

- `users`
- `salons`
- `barbers`
- `bookings`
- `joinRequests`

Collections are created when real users create their first records. Firestore
does not display empty collections, so `salons`, `barbers`, `bookings`, and
`joinRequests` appear after the first owner profile, staff member, booking, or
join request is saved.

## Deploy Firestore rules

```bash
firebase deploy --only firestore
```

## Android build

```bash
flutter build apk --release
```

For Play Store release, add a real release signing config before publishing.
