# Focelle Privacy Policy

Last updated: July 26, 2026

Focelle is an iPhone camera and AI photo-coaching app. This policy describes the beta build.

## What stays on the iPhone

- Camera access is used only to show the viewfinder, provide on-device composition guidance, and take a photo when the user presses the shutter. Camera frames are not retained by Focelle.
- Photos are added to the user's Apple Photos library only after an explicit capture/save attempt. Focelle requests add-only Photos permission at that time, not at launch.
- R1 does not enumerate, read back, or observe the user's Photo Library. Focelle does not operate a photo library or photo-storage service.
- Custom presets are stored locally and may sync through the user's private iCloud account.
- Photo location is off by default. If enabled, it is attached only to the saved photo and is not sent to Focelle, AI providers, or analytics.

## Optional cloud AI

Only after the user taps AI, Focelle creates a reduced JPEG preview, removes JPEG metadata, and sends it over HTTPS through a Focelle Cloudflare Worker to Google Gemini. The preview is used to return composition advice and is not written to Focelle storage. Google processes the preview under the terms applicable to the configured Gemini service. The free-tier service may use submitted content to improve Google products. Users can enable On-device only mode at any time.

This R1 capture and save work does not introduce any new cloud upload or cloud storage.

## Data Focelle processes

- A pseudonymous app/device identifier for beta access, quota, abuse prevention, and optional analytics.
- Product interactions such as AI success or failure, feature use, and broad latency categories when analytics is enabled.
- Purchase transaction identifiers, product identifiers, entitlement status, and credit balance when purchases are enabled.
- A hashed Sign in with Apple subject and an opaque session token when the user chooses to sync purchased credits.
- Referral codes and verified reward state when referrals are enabled.

Focelle does not request a user's name or email from Sign in with Apple. It does not collect face geometry, exact location, AI advice text, advertising identifiers for first-party analytics, contacts, health data, or sensitive-trait inferences.

## Advertising

The free beta shows no ads. A later free tier may offer only user-initiated, non-personalized rewarded ads. The Google Mobile Ads SDK may then process IP-derived coarse location, device identifiers, advertising data, product interaction, crash data, and performance data. Focelle does not request App Tracking Transparency permission and does not use ads for cross-app tracking.

## Service providers

- Apple: Photos, private iCloud preset sync, Sign in with Apple, and App Store purchases.
- Cloudflare: encrypted API proxy, feature configuration, quota, minimal account data, and operational storage.
- Google: optional Gemini image analysis and, only when enabled after beta, rewarded ads.

Focelle does not sell personal data.

## Controls and deletion

Users can turn off analytics, cloud AI, voice guidance, Auto Capture, and photo location in Settings. A signed-in user can delete the Focelle account in Settings; this removes account/session/device links and synced credit balance. Transaction records required for purchase verification, refunds, fraud prevention, accounting, or legal compliance may be retained. Users can also revoke camera, Photos, location, and iCloud access in iOS Settings.

## Security and children

Focelle uses HTTPS and keeps AI-provider and App Store credentials on the server. No system can be guaranteed completely secure. Focelle is a general photography app and is not directed to children under 13.

## Contact

The public support email and privacy-policy URL must be inserted here before TestFlight external testing or App Store submission.

Material changes will update the date above and, when appropriate, be explained in the app or release notes.

