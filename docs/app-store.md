# App Store Release Record

## Listing draft

- Name: Focelle
- Subtitle: Focelle - AI Photo Coach
- Primary category: Photo & Video
- Primary language: Vietnamese
- Version: 0.1.0
- Bundle ID: `com.pnhd.focelle`
- Copyright and seller name: required from the Apple Developer account holder
- Support URL: required before upload
- Privacy Policy URL: required before upload

Vietnamese promotional text:

> Gợi ý góc chụp, bố cục và màu sắc ngay trước khi bấm máy. Beta Pro đang miễn phí.

Vietnamese description:

> Focelle giúp người mới chụp chân dung, cặp đôi và nhóm nhỏ đẹp hơn. Ứng dụng hướng dẫn vị trí chủ thể, hướng di chuyển, độ nghiêng, ánh sáng và màu phù hợp ngay trên khung ngắm. Bạn vẫn có thể chụp, chỉnh filter và dùng hướng dẫn trên máy khi không có mạng. Ảnh AI chỉ được gửi ở độ phân giải thấp sau khi bạn chủ động bấm AI. Không làm mịn da, không thay đổi khuôn mặt hay cơ thể, không đóng watermark mặc định.

Keywords: `camera,AI,chụp ảnh,bố cục,góc chụp,filter,preset,chân dung`

## App Privacy answers

Choose **Yes, we collect data from this app**. Disclose the most inclusive behavior that can be enabled remotely:

| Apple data type | Purpose | Linked to user | Tracking |
|---|---|---:|---:|
| Photos or Videos | App Functionality (optional AI preview) | Yes, to the pseudonymous device ID in the same request | No |
| User ID | App Functionality (optional Sign in with Apple account) | Yes | No |
| Device ID | App Functionality, Analytics | Yes | No |
| Purchase History | App Functionality | Yes | No |
| Product Interaction | Analytics, App Functionality | Yes | No |
| Advertising Data | Third-Party Advertising, Analytics (rewarded ads only) | Follow the current Google SDK privacy report | No personalized tracking |
| Coarse Location | Third-Party Advertising (IP-derived, rewarded ads only) | Follow the current Google SDK privacy report | No personalized tracking |
| Crash Data | App Functionality/Analytics through Google Mobile Ads when enabled | Follow the current Google SDK privacy report | No |
| Performance Data | App Functionality/Analytics through Google Mobile Ads when enabled | Follow the current Google SDK privacy report | No |

Do not disclose precise location: optional photo location is written only to the user's photo and is never sent off device. Re-run Xcode's privacy report and compare it with Google's current Mobile Ads disclosure immediately before submission.

## Review notes

- Focelle opens directly to the camera and requires no account for free camera/filter use.
- Cloud AI is optional and has an On-device only switch.
- The beta is unlimited and ad-free. Store, referral, production ads, and their backend flags remain disabled.
- The included StoreKit test configuration is for local testing. App Store products must be created separately.
- AI, quota, purchase, account, and referral failures never block the manual shutter.
- No face recognition, beauty reshaping, hidden/private API, or background camera capture is used.

## Name clearance

A general web/App Store-style search on July 26, 2026 found no obvious photography app using the exact name “Focelle.” This is only a preliminary screening, not legal trademark clearance. Before public submission, search the Vietnam IP Office and WIPO Global Brand Database for the relevant software/photography classes and have the seller approve the risk.
