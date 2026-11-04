# Runbook — getting SCORE1000 onto your iPhone and iPad

SCORE1000 uses exactly the same build setup as VISION: same Apple Developer account, same App Store Connect API key, same GitHub account (`deven86`), signing stored encrypted on a `match-signing` branch of this repo, and uploads only when you press the button.

## 1. GitHub (2 minutes)
1. Create a **private** repo `deven86/score1000` (empty — no README).
2. In it: Settings → Secrets and variables → Actions → add the **same 4 secrets you used for VISION** (GitHub never shows secret values, so paste them again from where you saved them):

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | your Apple Team ID |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_P8_BASE64` | the base64 of the `.p8` key file |

If you no longer have the `.p8` file, create a new API key in App Store Connect → Users and Access → Integrations → App Store Connect API (App Manager role), and update VISION's secrets too.

## 2. App Store Connect (3 minutes)
1. My Apps → **+** New App → iOS → name e.g. "SCORE1000" (if taken, "SCORE1000 Analyst"), bundle ID **com.jondhale.score1000** (appears after step 3.1 below registers it), SKU `score1000`.
2. TestFlight tab → Internal Testing → add yourself.

## 3. First build (in GitHub → Actions)
1. **Signing setup** → Run workflow (once). Registers the App ID `com.jondhale.score1000`, turns on Data Protection, and stores the certificate + profile on the `match-signing` branch.
   - Apple allows only a few distribution certificates per account. If it fails with a "maximum number" error, revoke an unused one in Certificates, Identifiers & Profiles, or ask Claude to share VISION's certificate instead.
2. Create the App Store Connect app record (step 2.1) now that the bundle ID exists.
3. **iOS build & test** → Run workflow. Compiles and runs the unit tests (no secrets needed).
4. **TestFlight** → Run workflow → type `UPLOAD`. After ~10–20 minutes of Apple processing, install from the TestFlight app on iPhone and iPad.

TestFlight builds expire after 90 days — run **TestFlight** again before then.

## Mac minutes
The repo is private, so GitHub's free plan gives a limited number of macOS minutes per month, **shared with VISION** (macOS minutes count 10× toward the 2,000-minute free allowance, so roughly 200 real minutes). One build-and-upload takes about 15–25 minutes. That is why CI never runs automatically on push. Check usage at github.com/settings/billing.

## In the app
1. Unlock with Face ID.
2. Settings → AI Providers → paste your Anthropic key (optionally OpenAI / Gemini) → **Test & list models**.
3. Settings → Model Tiers → confirm Fast / Balanced / Deep.
4. Keys appear on the iPad through iCloud Keychain (Settings → [your name] → iCloud → Passwords & Keychain must be on).

## Security hygiene
- 2FA on Apple ID, GitHub and each AI console; set a monthly spend limit in each AI console.
- Never paste keys into GitHub issues, commits or chat.
