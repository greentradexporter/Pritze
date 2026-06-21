# Pritze Production Upload Checklist

Version: `1.0.3+5`
Package: `com.trimtime.app`
App name: `Pritze`

## Android Upload

- Play Store app bundle: `android/pritze-v1.0.3+5-release.aab`
- Direct install/test APK: `android/pritze-v1.0.3+5-release.apk`

SHA-256:

- AAB: `5b1415f65159ca8f9eef377d9114052cacddec449e4ea9a776a5662a10e46714`
- APK: `9c91ac7cf04d5b48dc01525ed6589659580ffdc70554afecfdd3d670694160aa`

## Store Assets

- App icon: `brand/pritze-app-icon-512.png`
- Feature graphic: `brand/pritze-feature-graphic-1024x500.png`
- Logo reference: `brand/pritze-logo.jpeg`
- Screenshots: `screenshots/01-home.png` through `screenshots/06-owner-signin.png`

## Suggested Release Notes

Improved Pritze branding and launcher fit, persistent customer bookings, barber request approvals, logout controls, reliable staff management, compact service selection, and polished booking confirmation actions.

## Before Public Store Submission

- Clean production Firestore listing data. Current live listing data still includes test-looking values such as lowercase salon/service names and unrealistic prices, which appear in screenshots and customer flows.
- Firebase Storage is intentionally not required. Shop logos use bundled/default app assets unless a future paid remote-storage option is enabled.
- Confirm Google sign-in provider and Email/Password provider remain enabled in Firebase Authentication.
