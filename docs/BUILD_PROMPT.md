# SCORE1000 — Master Build Prompt for Claude (Claude Code)

Paste everything below into Claude Code at the root of an empty private GitHub repository. Put the full specification PDF into `/docs/` as well, and tell Claude it is the source of truth.

---

## 0. Role and mindset

You are a principal iOS engineer, backend engineer and quantitative analyst working together as one team. You are building **SCORE1000**, a private AI market-analysis app for one user (Devendra) on his own iPhone and iPad, distributed only through internal TestFlight.

Real money depends on this app. That changes the priorities:

- Correctness, security and honest uncertainty come before features and visual polish.
- When a requirement is unsafe, impossible or unverifiable, say so once with the concrete failure mode, propose the safer alternative, and record the decision in `/docs/DECISIONS.md`.
- Never invent data, prices, sources or model names. If something is unknown, the app must show "unavailable", not a guess.

## 1. What the app does (one paragraph)

The user picks any tradable "product" (stock, index, ETF, F&O contract, commodity, currency pair, metal or crypto) from Indian and global markets. The system runs a 10-stage analysis. Each stage produces a 1–100 score with reasons and sources. A weighted engine combines them into a 10–1000 composite score with a Buy / Sell / No-trade verdict, a trade plan (entry zone, stop-loss, 3–5 take-profit stages, holding-period badge and complete-by date), and a plain-language explanation of how the score was reached. Confirmed trades are monitored by a backend server at a cadence that matches the chosen timeframe, with emergency alerts when the plan breaks. An "AI Recommendation" mode screens a chosen market and proposes the best candidates. All history is stored and synced between iPhone and iPad through iCloud.

## 2. Non-negotiable engineering rules

1. **Code computes, AI interprets.** LLMs never read raw candle arrays and never do arithmetic that matters. The feature engine computes indicators, patterns, levels, correlations and statistics; the LLM receives compact feature JSON and explains or weighs it.
2. **Strict JSON or nothing.** Every AI stage returns JSON validated against the schemas in `/shared/schemas`. Invalid output → one retry with the validation error → otherwise the stage is marked `unavailable` (score 50, confidence 0) and the report shows that clearly.
3. **Every claim is traceable.** Each reason cites a source (URL + published time) or a feature ID from the feature pack. Uncited reasons are dropped by the validator.
4. **No hard-coded model names, prices or endpoints.** All AI calls go through one `AIProvider` protocol/interface. Models are listed live from the provider after the user enters a key. Tier→model mapping (Fast / Balanced / Deep) lives in Settings. Model prices come from a remote JSON config that the user can edit.
5. **No order placement in v1.** The app suggests; the user executes in the broker app. (Order placement would trigger SEBI retail-algo rules: static IP, Algo ID, daily 2FA, <10 orders/second.)
6. **Secrets live in the Keychain only** (iOS) and in encrypted server secrets (backend). Never in SwiftData, CloudKit, UserDefaults, logs, analytics or crash reports.
7. **The phone is not the monitoring engine.** iOS cannot run reliable 1-minute background jobs. All monitoring, rules and alerts run on the backend and reach the phone through APNs.
8. **Time is explicit.** Store UTC; display exchange time and IST. Use exchange trading calendars and holidays (NSE/BSE/MCX, NYSE/NASDAQ, 24×7 crypto, 24×5 FX).
9. **Full audit trail.** Every analysis stores: product, data-as-of timestamps, feature-pack hash, prompt template version, provider + model ID per stage, raw AI output, validated output, scores, verdict, cost.
10. **Paper mode is the default.** Real-money mode needs an explicit toggle plus Face ID confirmation.
11. **Show uncertainty everywhere.** Each score shows confidence, data freshness, and the historical hit-rate of that score band (calibration) once enough outcomes exist.
12. **Accessibility is not optional.** Dynamic Type, VoiceOver labels on every chart value, Reduce Transparency, Increase Contrast, colour-blind-safe up/down colours.

## 3. Tech stack (decided — change only with a written reason)

**iOS / iPadOS app**
- Swift 6, SwiftUI, minimum deployment target iOS 26 / iPadOS 26 (both devices are personal; this unlocks Liquid Glass and current SwiftData). Build with Xcode 26.x.
- SwiftData with CloudKit private database for user data (sync iPhone ↔ iPad).
- Keychain (`kSecAttrSynchronizable = true`, `kSecAttrAccessibleWhenUnlocked`) for AI API keys so they sync via end-to-end-encrypted iCloud Keychain.
- LocalAuthentication (Face ID / passcode) app lock.
- Charts: Swift Charts for gauges, sparklines, portfolio and score history; TradingView Lightweight Charts (Apache-2.0, bundled locally, attribution shown) inside WKWebView for the full interactive candlestick chart.
- WidgetKit (Home Screen, Lock Screen, StandBy), ActivityKit Live Activities for open intraday positions, App Intents for Siri/Shortcuts.
- Swift Concurrency everywhere; no blocking the main actor.

**Backend (required)**
- Python 3.12, FastAPI, PostgreSQL, Redis, a job scheduler (APScheduler or Celery beat), pandas/numpy + a technical-analysis library for features.
- Hosted on a small Linux VPS in an Indian region (Mumbai/Bangalore) with a static IP, Docker Compose, Caddy (automatic HTTPS), UFW firewall, SSH keys only, unattended security updates, nightly encrypted Postgres backup.
- APNs via token-based auth (.p8 key) for alerts and Live Activity updates.

## 4. Repository layout

```
/ios/Score1000.xcodeproj
/ios/Score1000/            App target (Features/, Core/, DesignSystem/, Services/)
/ios/Score1000Widgets/     Widgets + Live Activity
/ios/Score1000Tests/       Unit + snapshot tests
/backend/app/              api/, data/, features/, ai/, scoring/, monitor/, notify/, jobs/
/backend/tests/
/shared/schemas/           stage_output.schema.json, trade_plan.schema.json, feature_pack.schema.json
/shared/prompts/           stage_01_news.md ... stage_10_final.md, verifier.md (versioned)
/shared/config/            model_prices.json, scoring_weights.json, alert_rules.json
/docs/                     SPEC.pdf, DECISIONS.md, RUNBOOK.md, DATA_SOURCES.md
/fastlane/                 Fastfile, Matchfile, Appfile
/.github/workflows/        ios-testflight.yml, backend-ci.yml, monthly-rebuild.yml
```

## 5. Data layer

Implement a `MarketDataProvider` interface on the backend with adapters, chosen per product by a routing table:

- **India (NSE, BSE, NFO, MCX, CDS):** Upstox API v3 (free with an account; historical candles: 1-min–hour from Jan 2022, daily/weekly/monthly from Jan 2000; live WebSocket). Fyers API as fallback. Daily login: the app opens the broker OAuth page each trading morning; the token is stored only on the backend.
- **Instrument master:** download Upstox's complete instrument file daily, plus global symbol lists from the global provider and crypto lists; build a searchable `instruments` table (symbol, name, exchange, segment, asset class, lot size, tick size, expiry, ISIN, sector).
- **Global equities, indices, FX (incl. USD/INR), XAUUSD/XAGUSD:** Twelve Data (free Basic: 800 calls/day, 8/min) behind a cache; upgrade path EODHD or Twelve Data Grow.
- **Crypto:** Binance public market data; CoinGecko Demo for metadata.
- **News/events:** NSE official RSS (announcements, board meetings, financial results, circulars), Finnhub or Marketaux news, FRED/BLS release calendars; AI web search for stages that need it.
- **Rules:** respect each provider's rate limits with a token-bucket limiter; cache candles in Postgres (immutable closed bars) and Redis (live); mark every series with `as_of` and `source`; never show scraped/unofficial data as "official".
- Record provider terms in `/docs/DATA_SOURCES.md`. Exchange data is for personal use only; the app must not redistribute it.

## 6. Feature engine (code, not AI)

For each product build a **feature pack** (JSON, < 8k tokens) per timeframe: 1M, 1W, 1D, 1H, 15m, 5m.

- Trend: SMA/EMA stack (20/50/100/200), slope, ADX, higher-highs/lower-lows structure.
- Momentum: RSI, MACD, rate of change, divergences.
- Volatility: ATR, ATR %, Bollinger width, historical volatility percentile.
- Volume: relative volume, OBV trend, delivery % (India, where available).
- Levels: swing highs/lows, support/resistance clusters, 52-week range, round numbers, VWAP and opening range (intraday).
- Patterns: candlestick and chart patterns with this symbol's own historical hit-rate and sample size (backtested in code).
- History (stage 4): CAGR, max drawdowns with dates, regime segmentation (bull/bear/sideways periods with start/end), top 10 largest monthly moves with dates.
- Cross-asset (stage 8): rolling 60/250-bar correlations and lead-lag with the related products.
- Every feature has a stable ID (e.g. `D.RSI14`, `W.SR.zone2`) so AI reasons can cite it.

## 7. The 10-stage pipeline and model tiers

| # | Stage | Code does first | AI tier | Web search | Refresh/cache |
|---|---|---|---|---|---|
| 1 | Product news | Fetch + dedupe articles (last 7–30 days) | Fast (per-article classify) → code aggregates with time decay | Optional | 1–4 h |
| 2 | Upcoming events | Results dates, dividends, board meetings, splits, macro calendar | Balanced | Yes | Daily |
| 3 | Leadership / governance / country | Promoter holding, pledges, auditor, ratings where available | Balanced | Yes | 7–30 days |
| 4 | Full monthly history + why | Regimes, drawdowns, biggest moves with dates | **Deep** | Yes | 30 days |
| 5 | Weekly, last 6 months | Weekly features + patterns with hit-rates | Fast | No | Weekly |
| 6 | Daily, full history | Daily features + backtested pattern stats | Fast (escalate to Balanced if signals conflict) | No | Daily |
| 7 | Global sector/theme news | Sector mapping; shared per sector | Balanced | Yes | Daily, shared by all symbols in the sector |
| 8 | Sister/connected products | Relationship map + rolling correlations | Balanced (map, cached 30 d) + Fast (current read) | Yes for map | Daily |
| 9 | Today + 1 week outlook | Intraday + daily features, VWAP, ranges | Balanced | Optional | Each run |
| 10 | Final multi-timeframe verdict + trade plan | Feature packs 5m→1M + all stage outputs | **Deep** with extended thinking | Yes (re-check) | Each run |
| V | Verifier | Re-checks numbers, levels and schema against features | Fast (prefer a different provider) | No | Each run |

Other jobs:
- Live monitoring (1m–15m): **no LLM per tick.** Deterministic rules engine on the backend; Fast model only to word an alert summary after a trigger.
- Daily review of each open position: Balanced via the provider's batch API (cheaper) after market close.
- Weekly deep re-score of open positions: Deep.
- AI Recommendation mode: code screens the universe → Fast triage of top ~50 → full pipeline on top 5–10.
- "Explain this score" chat: Balanced.

Default mapping (user can change in Settings after models are listed live):
- Fast = Claude Haiku tier (e.g. `claude-haiku-5-5`) / OpenAI nano–mini tier / Gemini Flash-Lite tier
- Balanced = Claude Sonnet tier / OpenAI mid tier / Gemini Flash tier
- Deep = Claude Opus tier (e.g. `claude-opus-5-5`) / OpenAI top tier / Gemini Pro tier

Use prompt caching for the shared system prompt and feature-pack prefix. Enforce a per-run and per-month spend cap from Settings; show estimated cost before running AI Recommendation mode.

## 8. Stage output schema (all stages)

```json
{
  "stage": 1,
  "product_id": "NSE_EQ|INE002A01018",
  "score": 72,
  "direction": "bullish",
  "confidence": 0.65,
  "horizon_relevance": "short|medium|long",
  "summary": "max 60 words",
  "reasons": [
    {"point": "text", "impact": 2, "evidence": ["D.RSI14", "src:3"]}
  ],
  "sources": [
    {"id": "src:3", "title": "", "url": "", "published_at": "ISO-8601"}
  ],
  "data_as_of": "ISO-8601",
  "warnings": []
}
```
Score meaning: 1 = strongly bearish, 50 = neutral, 100 = strongly bullish. `impact` is −3…+3.

## 9. Scoring engine (deterministic code)

1. Confidence shrink: `s_eff = 50 + confidence × (score − 50)`.
2. Horizon weights from `/shared/config/scoring_weights.json` (each row sums to 100):

| Stage | Scalp/Intraday | Swing | Positional | Long-term | Equal |
|---|---|---|---|---|---|
| 1 News | 8 | 10 | 10 | 8 | 10 |
| 2 Upcoming | 4 | 8 | 10 | 10 | 10 |
| 3 Leadership | 0 | 3 | 8 | 15 | 10 |
| 4 Monthly history | 0 | 4 | 10 | 20 | 10 |
| 5 Weekly 6M | 2 | 10 | 14 | 10 | 10 |
| 6 Daily | 10 | 15 | 12 | 5 | 10 |
| 7 Global sector | 4 | 8 | 10 | 12 | 10 |
| 8 Connected | 8 | 8 | 8 | 8 | 10 |
| 9 Today + 1W | 24 | 14 | 6 | 2 | 10 |
| 10 Final | 40 | 20 | 12 | 10 | 10 |

3. Composite `C = 10 × Σ(w_i × s_eff_i) / 100` → range 10–1000. Buy score = C; Sell score = 1010 − C.
4. Verdict bands: ≥ 750 Strong Buy · 620–749 Buy · 381–619 No trade / Wait · 251–380 Sell · ≤ 250 Strong Sell.
5. Vetoes (downgrade to "No trade" with the reason shown): stale data beyond the timeframe limit; results/major event inside the holding window (unless the user opts in); liquidity or spread below thresholds; verifier finds a numeric mismatch; fewer than 7 of 10 stages available.
6. Store everything; nightly job records outcomes (did TP1 hit before SL? return at horizon end) and computes calibration per score band and per stage.

## 10. Trade plan (stage 10 + code)

- Entry zone, stop-loss (structure- or ATR-based), R = |entry − stop|.
- Take-profit ladder (user picks 3, 4 or 5 stages). Default 5-stage: TP1 = 1R (book 30 %, move stop to breakeven) · TP2 = 2R (25 %, trail stop to TP1) · TP3 = 3R (20 %) · TP4 = 4R (15 %) · TP5 = runner with ATR trailing stop (10 %). Code snaps levels to nearby resistance/support.
- Position size = (capital × risk %) / R (default risk 1 %; max 2 %).
- Holding badge: Scalp · Intraday · Short-term (2–10 trading days) · Swing (2–6 weeks) · Positional (1–6 months) · Long-term (6 months+). Complete-by date = entry + max holding; on expiry the app asks: exit or re-analyse.
- AI may propose levels; code validates ordering (stop < entry < TP1 < … for longs), minimum R:R ≥ 1.5 at TP2, and tick-size rounding.

## 11. Monitoring and emergency protocol (backend)

Cadence follows the chosen timeframe:
- 1m/5m: broker WebSocket ticks, rules on every tick/bar close, Live Activity updates.
- 15m/1h: every bar close.
- Daily: intraday price-alert rules live + full review after the close.
- Weekly/monthly: price-alert rules live + daily close check + weekly deep review.

Upcoming-trade watch: when price comes within the proximity band of the AI entry zone (default 0.5 × ATR), send "Entry zone reached" with the current score re-checked.

Emergency triggers: E1 stop/invalidation crossed · E2 gap beyond stop or > 2 ATR adverse · E3 adverse velocity > 1.5 ATR within N bars · E4 news shock (stage-1 rescan drop ≥ 25 or keywords: fraud, raid, SEBI order, default, CEO resignation, trading halt) · E5 thesis broken (composite crosses to the opposite band) · E6 data feed or server heartbeat lost ("Monitoring offline") · E7 complete-by date passed.

Emergency actions: time-sensitive push (repeat every 2 min until acknowledged, max 5), red Live Activity, full-screen in-app takeover with "Close now" checklist, entry in the journal. Always remind the user to keep a real stop-loss/GTT order at the broker — push delivery can be delayed.

## 12. Data model (SwiftData, CloudKit-compatible)

Rules: no `@Attribute(.unique)`; every property has a default or is optional; every relationship optional; no `.deny` delete rule; schema is additive after production promotion.

Entities: `Product`, `Watchlist`, `AnalysisRun`, `StageResult`, `TradePlan`, `TakeProfitLevel`, `Position` (planned → entered → partially closed → closed), `Fill`, `PositionReview`, `AlertEvent`, `RecommendationRun`, `CalibrationSnapshot`, `UserSettings`. Large raw payloads (feature packs, raw AI output) stay on the backend; the app stores IDs + summaries.

## 13. UI / UX

- **Liquid Glass (iOS 26):** let system navigation, tab bars, toolbars and sheets adopt glass automatically. Use `.glassEffect()` only for floating controls (score chip, quick-action bar, timeframe picker), group them in `GlassEffectContainer`, morph with `glassEffectID(_:in:)`, buttons with `.buttonStyle(.glass)` / `.glassProminent`. Never put glass behind dense numbers, tables or candles. When Reduce Transparency is on, fall back to solid surfaces.
- **Themes:** Liquid Glass (default) · Calm Light · Calm Dark (#121417, not pure black) · OLED Night · Paper (warm, low blue) · High Contrast. Up/down colours softened; colour-blind option (blue/orange). Numbers in SF Pro with `.monospacedDigit()`.
- **Screens (iPhone tab bar; iPad `NavigationSplitView`):** Lock → Home (today's alerts, open positions, upcoming trades) → Markets (search all products, filters by exchange/asset class/sector, watchlists) → Analyse (live stage-by-stage progress cards, cancellable) → Score Report (0–1000 gauge, verdict, 10 stage cards each with score, reasons, sources, model used; "How this score was calculated" breakdown with weights) → Trade Plan (chart with entry/stop/TP levels, badge, complete-by date, size calculator) → Upcoming Trades → Positions → Journal (invested, realised/unrealised P&L, win rate, average R, AI calibration) → AI Recommendations → Alerts Center → Settings (AI providers & keys, model tiers, spend caps, risk %, themes, lock, data sources, paper/real mode).
- Motion: subtle, 200–300 ms, respects Reduce Motion. Loading states are skeletons shaped like the content; every AI wait has a cancel button.

## 14. Security checklist

- Face ID/passcode on launch and after 30 s in background; privacy cover in the app switcher; Face ID re-confirm for viewing keys, switching to real-money mode, and exporting data.
- AI keys: Keychain (synced). If server-side jobs need them, send once over TLS to the backend and store encrypted at rest; a Settings switch shows which keys the server holds and can wipe them.
- Backend auth: Sign in with Apple + single-user allowlist + short-lived JWT, or a Secure Enclave device key signing each request. Certificate pinning (`NSPinnedDomains`) for your own backend only. ATS on, no arbitrary loads.
- Prompt-injection defence: news/web text is wrapped as untrusted data; models get no tools that act on accounts; outputs schema-validated; numbers recomputed by code.
- Server hardening as in §3; 2FA on Apple ID, GitHub, broker, VPS and AI consoles; secrets in GitHub Actions encrypted secrets.
- Privacy-sensitive redaction for widgets/Live Activities on the Lock Screen (option to hide P&L).

## 15. CI/CD: GitHub → TestFlight → iPhone/iPad

- `ios-testflight.yml` on `runs-on: macos-26`; select a pinned Xcode 26.x; fastlane `match` (private certs repo) + App Store Connect API key (.p8, Key ID, Issuer ID as secrets); `build_app` → `upload_to_testflight` to the **internal** group (no Beta App Review).
- Bump build number from the run number. Run unit tests before upload.
- `monthly-rebuild.yml`: scheduled rebuild + upload so a TestFlight build never hits the 90-day expiry.
- `backend-ci.yml`: lint, tests, build Docker image, deploy over SSH to the VPS on tag.

## 16. Milestones and acceptance tests

Work milestone by milestone. At the start of each: write a short plan. At the end: run tests, update `/docs/DECISIONS.md`, and list what the user must do manually (accounts, keys, approvals).

- **M1 Foundation:** project, design system + 6 themes, Face ID lock, Keychain key storage, AI provider screen that lists live models for Anthropic/OpenAI/Gemini, CI uploading to TestFlight. ✓ App installs on iPhone and iPad from TestFlight; keys sync; lock works.
- **M2 Backend + data:** VPS, auth, Upstox login flow, instrument master, candles + caching, global/crypto adapters, product search, candlestick chart. ✓ Search finds RELIANCE (NSE), XAUUSD, AAPL, BTCUSDT; charts load 1m→1M.
- **M3 Feature engine + backtest harness:** all features, pattern hit-rates, feature-pack JSON. ✓ Golden tests against hand-checked values.
- **M4 AI stages + scoring:** 10 stages + verifier, schemas, weights, vetoes, Score Report UI with explanations and sources. ✓ Invalid AI JSON never reaches UI; each reason cites evidence; cost per run logged.
- **M5 Trade plan + trades:** TP ladder, sizing, badges, Upcoming Trades, Positions, Journal with P&L. ✓ Level ordering validator; P&L matches manual calculation.
- **M6 Monitoring + alerts:** rules engine, APNs, Live Activities, widgets, emergency protocol, heartbeat. ✓ Simulated feed triggers each E1–E7 alert on device within 10 s.
- **M7 AI Recommendation mode:** screener → triage → full pipeline, cost preview. ✓ Runs within the spend cap.
- **M8 Calibration + hardening:** outcome tracking, calibration charts, security review, failure drills (kill data feed, kill AI provider, expire broker token). ✓ App degrades with clear messages, never shows a fabricated score.

Paper-trade for at least 4–8 weeks and review calibration before using real-money mode.
