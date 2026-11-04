# SCORE1000

Private AI market-scoring app for iPhone and iPad (personal use, internal TestFlight only). Not investment advice.

- Spec: [`docs/SPEC.pdf`](docs/SPEC.pdf) · Build prompt: [`docs/BUILD_PROMPT.md`](docs/BUILD_PROMPT.md)
- Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md) · Setup: [`docs/RUNBOOK.md`](docs/RUNBOOK.md)

## Layout
```
ios/            SwiftUI app (XcodeGen spec in ios/project.yml)
backend/        FastAPI server (from M2)
shared/         JSON schemas, scoring weights, model prices, prompts
fastlane/       signing + TestFlight lanes
.github/        CI workflows
```

## Develop locally (Mac)
```
brew install xcodegen
cd ios && xcodegen generate && open Score1000.xcodeproj
```

## Milestones
- [x] **M1 Foundation** — themes, Liquid Glass, Face ID lock, Keychain keys, live AI model listing, tier mapping, CI → TestFlight
- [ ] M2 Backend + market data
- [ ] M3 Feature engine
- [ ] M4 AI stages + scoring
- [ ] M5 Trade plans, positions, journal
- [ ] M6 Monitoring + alerts
- [ ] M7 AI Recommendations
- [ ] M8 Calibration + hardening
