# Runbook — getting SCORE1000 onto your iPhone and iPad

These are the steps only you can do. Do them once, in this order.

## 1. Apple
1. Enrol in the Apple Developer Program (developer.apple.com/programs). Note your **Team ID** (Membership page, 10 characters).
2. Certificates, Identifiers & Profiles → Identifiers → **+** → App ID → Bundle ID `com.devendrajondhale.score1000` (or your own; then change `BUNDLE_ID_PREFIX` in `ios/project.yml` and `fastlane/Appfile`).
3. App Store Connect → My Apps → **+** New App → iOS, name "SCORE1000" (any unique name), the bundle ID above, SKU `score1000`.
4. App Store Connect → Users and Access → Integrations → **App Store Connect API** → generate a key with **App Manager** access. Download the `.p8` once. Note **Key ID** and **Issuer ID**.
5. TestFlight tab → Internal Testing → create group "Me" → add yourself.

## 2. GitHub
1. Create two **private** repos: `score1000` (this code) and `score1000-certs` (empty; fastlane match stores encrypted signing certificates here).
2. Create a fine-grained personal access token with read/write **Contents** on `score1000-certs`.
3. In `score1000` → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | your Team ID |
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | output of `base64 -i AuthKey_XXXX.p8` |
| `MATCH_GIT_URL` | `https://github.com/<you>/score1000-certs.git` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | output of `echo -n "<github-username>:<token>" \| base64` |
| `MATCH_PASSWORD` | a long passphrase you invent (keep it safe — it encrypts your certificates) |

## 3. First TestFlight build
1. Push this code to `score1000` on branch `main`.
2. Actions → **iOS build & test** should go green (compiles and runs unit tests on a simulator; needs no secrets).
3. Actions → **iOS TestFlight** → Run workflow → tick **create_certs** the first time only. This creates the distribution certificate + profile in `score1000-certs`, builds, and uploads.
4. Wait ~10–20 min for Apple processing; the build appears in the TestFlight app on your iPhone and iPad.
5. Builds expire after 90 days; **Monthly rebuild** re-uploads automatically on the 1st of each month.

## 4. In the app
1. Unlock with Face ID.
2. Settings → AI Providers → paste your Anthropic key (optionally OpenAI / Gemini) → **Test & list models**.
3. Settings → Model Tiers → confirm the suggested Fast / Balanced / Deep models.
4. Keys appear on your iPad automatically through iCloud Keychain (iCloud Keychain must be on: Settings → [your name] → iCloud → Passwords & Keychain).

## Security hygiene
- Turn on 2FA for Apple ID, GitHub, each AI console; set a monthly spend limit in each AI console.
- Never paste keys into GitHub issues, commits or chat.
