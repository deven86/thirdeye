# Third Eye

Private AI market-scoring app for iPhone and iPad (personal use, internal TestFlight only). Not investment advice.

- Spec: [`docs/SPEC.pdf`](docs/SPEC.pdf) · Build prompt: [`docs/BUILD_PROMPT.md`](docs/BUILD_PROMPT.md)
- Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md) · Setup: [`docs/RUNBOOK.md`](docs/RUNBOOK.md)
- Build pipeline: same as VISION (GitHub Actions → fastlane match on `match-signing` branch → manual TestFlight upload)

## Layout
```
ios/            SwiftUI app (XcodeGen spec in ios/project.yml)
backend/        FastAPI server (from M2)
shared/         JSON schemas, scoring weights, model prices, prompts
fastlane/       signing lanes (match)
ci/             export options for TestFlight upload
.github/        CI workflows
```

## Develop locally (Mac)
```
brew install xcodegen
cd ios && xcodegen generate && open ThirdEye.xcodeproj
```

## Milestones
- [x] **M1 Foundation** — themes, Liquid Glass, Face ID lock, Keychain keys, live AI model listing, tier mapping, CI → TestFlight (VISION pipeline)
- [x] **M2 Markets (phone-first)** — Upstox login, every NSE/BSE/F&O/MCX product, US/forex/gold, crypto, search, live candlestick charts, watchlist
- [x] **M3 Feature engine** — indicators verified against TA-Lib, support/resistance, patterns with their own hit rates, history phases, Technicals panel
- [x] **M4 10-stage AI analysis** — Claude with web search, validated stage outputs, code-computed 0–1000 score, vetoes, trade plan with TP ladder, verifier, full report
- [x] **M5 Trades** — upcoming trades, entries/exits, TP tracking, position sizing, P&L journal, paper/real mode, iCloud sync
- [ ] M6 Monitoring + alerts
- [x] **M7 Hot trades** — code screen → AI shortlist → full analysis of top 3; HOT only when every check passes
- [x] **0.8 Scoring v2** — confidence-weighted score, explicit checks with grades and Watch levels, history check of the plan, cleaner Hot-trades universe (DECISIONS #38–43)
- [ ] **M6 Alerts** — Windows PC monitor (Go) + native push; setup guide [docs/ALERTS.md](docs/ALERTS.md) (DECISIONS #46–50)
- [x] **0.9 extras** — report card (grades every analysis afterwards), stage reuse for cheaper repeats, risk guard (DECISIONS #51–53)
- [ ] **Lock Screen live trade + widgets** — after alerts work (needs App Group + widget extension)
- [ ] M8 Calibration + hardening
