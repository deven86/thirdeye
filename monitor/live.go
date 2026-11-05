package main

import (
	"encoding/json"
	"fmt"
	"math"
	"time"
)

// LiveActivity is one trade shown on the iPhone Lock Screen / Dynamic Island, updated from here by push.
type LiveActivity struct {
	TradeID     string    `json:"tradeID"`
	Token       string    `json:"token"` // the activity's push token (changes when iOS rotates it)
	Environment string    `json:"environment"`
	BundleID    string    `json:"bundleID"`
	TeamID      string    `json:"teamID"`
	StartedAt   time.Time `json:"startedAt"`
	LastSent    time.Time `json:"lastSent"`
	LastStatus  string    `json:"lastStatus"`
	LastPrice   float64   `json:"lastPrice"`
	LastError   string    `json:"lastError,omitempty"`
}

// iOS ends a Live Activity after at most 12 hours (8 active + 4 on the Lock Screen); after that its token is useless.
const liveMaxAge = 12 * time.Hour

// LiveState is the activity's content. The JSON keys must match TradeActivityAttributes.ContentState in the app.
type LiveState struct {
	Price           float64  `json:"price"`
	R               *float64 `json:"r,omitempty"`
	PnlPercent      *float64 `json:"pnlPercent,omitempty"`
	Stop            float64  `json:"stop"`
	NextTarget      *float64 `json:"nextTarget,omitempty"`
	NextTargetStage *int     `json:"nextTargetStage,omitempty"`
	Progress        float64  `json:"progress"` // 0 = at the stop … 1 = at the next target
	Status          string   `json:"status"`   // waiting · inZone · open · nearStop · stop · target
	Note            string   `json:"note,omitempty"`
	UpdatedAt       float64  `json:"updatedAt"` // Unix seconds
}

// BuildLiveState turns a fresh price into the activity's content.
func BuildLiveState(t WatchTrade, price float64, now time.Time) LiveState {
	s := LiveState{Price: price, Stop: t.Stop, UpdatedAt: float64(now.Unix())}
	long := t.Long()
	dir := 1.0
	if !long {
		dir = -1
	}
	p := func(v float64) string { return money(v, t.Currency) }
	var next *Target
	for i := range t.Targets {
		tg := t.Targets[i]
		if !tg.Booked && tg.Price != nil {
			next = &tg
			break
		}
	}
	if next != nil {
		v, st := *next.Price, next.Stage
		s.NextTarget, s.NextTargetStage = &v, &st
	}
	if t.Status == "upcoming" {
		if price >= t.EntryLow && price <= t.EntryHigh {
			s.Status, s.Note = "inZone", fmt.Sprintf("In the entry zone %s–%s", p(t.EntryLow), p(t.EntryHigh))
		} else {
			edge := t.EntryLow
			if price > t.EntryHigh {
				edge = t.EntryHigh
			}
			s.Status, s.Note = "waiting", fmt.Sprintf("%.1f%% from the entry zone", math.Abs(price/edge-1)*100)
		}
		return s
	}
	risk := t.Risk()
	entry := t.Entry()
	if risk > 0 {
		r := dir * (price - entry) / risk
		s.R = &r
	}
	if entry > 0 {
		pct := dir * (price/entry - 1) * 100
		s.PnlPercent = &pct
	}
	if next != nil {
		span := dir * (*next.Price - t.Stop)
		if span > 0 {
			s.Progress = math.Max(0, math.Min(1, dir*(price-t.Stop)/span))
		}
	} else {
		s.Progress = 1
	}
	switch {
	case (long && price <= t.Stop) || (!long && price >= t.Stop):
		s.Status, s.Note = "stop", "Stop reached — exit what is left"
	case next != nil && ((long && price >= *next.Price) || (!long && price <= *next.Price)):
		s.Status, s.Note = "target", fmt.Sprintf("TP%d reached — book %.0f%%", next.Stage, next.BookPercent)
	case risk > 0 && dir*(price-t.Stop)/risk <= 0.25:
		s.Status, s.Note = "nearStop", "Close to the stop"
	default:
		s.Status = "open"
	}
	return s
}

// LiveDecision says whether to push now, and how urgently.
type LiveDecision struct {
	Send     bool
	Priority int  // 10 = now (status changed), 5 = when convenient (Apple's budget-friendly priority)
	Alert    bool // light up the screen (stop, target)
}

// DecideLive pushes on every status change at once, otherwise at most once a minute and only if the price moved.
func DecideLive(la LiveActivity, st LiveState, now time.Time) LiveDecision {
	if st.Status != la.LastStatus {
		return LiveDecision{Send: true, Priority: 10, Alert: st.Status == "stop" || st.Status == "target"}
	}
	if now.Sub(la.LastSent) >= time.Minute && st.Price != la.LastPrice {
		return LiveDecision{Send: true, Priority: 5}
	}
	return LiveDecision{}
}

// LivePayload builds the APNs body for an update (or "end").
func LivePayload(st LiveState, event string, alert bool, symbol string, now time.Time) []byte {
	aps := map[string]any{
		"timestamp":     now.Unix(),
		"event":         event,
		"content-state": st,
		"stale-date":    now.Add(30 * time.Minute).Unix(),
	}
	if event == "end" {
		aps["dismissal-date"] = now.Add(2 * time.Hour).Unix()
		delete(aps, "stale-date")
	}
	if alert {
		aps["alert"] = map[string]string{"title": symbol, "body": st.Note}
	}
	b, _ := json.Marshal(map[string]any{"aps": aps})
	return b
}
