package main

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

// Sample is one observed price.
type Sample struct {
	At    time.Time `json:"at"`
	Price float64   `json:"p"`
}

// Memory is what the monitor remembers per trade between checks.
type Memory struct {
	Fired       map[string]time.Time `json:"fired"` // alert key → when it fired (prevents repeats)
	Samples     []Sample             `json:"samples"`
	LastPrice   float64              `json:"lastPrice"`
	LastCheck   time.Time            `json:"lastCheck"`
	Fingerprint string               `json:"fingerprint"`
}

const (
	suddenWindow   = 60 * time.Minute
	suddenCooldown = 2 * time.Hour
	gapPause       = 6 * time.Hour
)

// resetForPlanChange re-arms the alerts that depend on the stop, the zone or the status.
func (m *Memory) resetForPlanChange(t WatchTrade) {
	if m.Fingerprint == t.Fingerprint() {
		return
	}
	for k := range m.Fired {
		if k == "entry" || k == "invalid" || k == "stop" || k == "near-stop" {
			delete(m.Fired, k)
		}
	}
	m.Fingerprint = t.Fingerprint()
}

// Evaluate checks one trade against a fresh price and returns the alerts to send. It updates m.
func Evaluate(t WatchTrade, price float64, now time.Time, m *Memory, s Settings, loc *time.Location) []Alert {
	if m.Fired == nil {
		m.Fired = map[string]time.Time{}
	}
	m.resetForPlanChange(t)
	s = s.withDefaults()
	var out []Alert
	risk := t.Risk()
	long := t.Long()
	dir := 1.0
	if !long {
		dir = -1
	}
	p := func(v float64) string { return money(v, t.Currency) }
	fire := func(key, kind, title, body string, urgent bool) {
		if _, done := m.Fired[key]; done {
			return
		}
		m.Fired[key] = now
		out = append(out, Alert{ID: newID(), TradeID: t.ID, Symbol: t.Symbol, Kind: kind, Title: title, Body: body,
			Urgent: urgent, Price: price, At: now})
	}
	sideWord := "long"
	if !long {
		sideWord = "short"
	}
	prevPrice, prevAt := m.LastPrice, m.LastCheck

	switch t.Status {
	case "upcoming":
		inZone := price >= t.EntryLow && price <= t.EntryHigh
		if inZone {
			tp1 := ""
			for _, tg := range t.Targets {
				if tg.Price != nil {
					tp1 = ", TP1 " + p(*tg.Price)
					break
				}
			}
			fire("entry", "entry", t.Symbol+" · entry zone reached",
				fmt.Sprintf("Price %s is inside %s–%s (%s). Stop %s%s. Record your entry in Third Eye.",
					p(price), p(t.EntryLow), p(t.EntryHigh), sideWord, p(t.Stop), tp1), false)
		} else if risk > 0 {
			dist := t.EntryLow - price
			if price > t.EntryHigh {
				dist = price - t.EntryHigh
			}
			if dist >= 0.5*risk {
				delete(m.Fired, "entry") // left the zone clearly: alert again on the next visit
			}
		}
		if (long && price <= t.Stop) || (!long && price >= t.Stop) {
			fire("invalid", "invalid", t.Symbol+" · setup invalidated",
				fmt.Sprintf("Price %s went past the planned stop %s before entry. Cancel this plan or re-analyse.",
					p(price), p(t.Stop)), false)
		}
		if !t.CompleteBy.IsZero() && now.After(t.CompleteBy) {
			fire("expired", "expired", t.Symbol+" · plan expired",
				fmt.Sprintf("The entry zone was not reached by %s. Cancel the plan or re-analyse.",
					t.CompleteBy.In(loc).Format("2 Jan")), false)
		}

	case "open":
		stopHit := (long && price <= t.Stop) || (!long && price >= t.Stop)
		if stopHit {
			result := ""
			if risk > 0 {
				result = fmt.Sprintf(" — about %+.1fR", dir*(price-t.Entry())/risk)
			}
			fire("stop", "stop", "⛔ "+t.Symbol+" · STOP HIT",
				fmt.Sprintf("Price %s reached your stop %s (%s). Exit what is left now%s.", p(price), p(t.Stop), sideWord, result), true)
		} else if risk > 0 {
			distR := dir * (price - t.Stop) / risk
			if distR <= 0.25 {
				fire("near-stop", "near-stop", t.Symbol+" · close to your stop",
					fmt.Sprintf("Price %s is %.2fR from the stop %s. Make sure a real stop order is placed at your broker.",
						p(price), distR, p(t.Stop)), true)
			} else if distR >= 0.5 {
				delete(m.Fired, "near-stop")
			}
		}
		if !stopHit {
			for _, tg := range t.Targets {
				if tg.Booked || tg.Price == nil {
					continue
				}
				if (long && price >= *tg.Price) || (!long && price <= *tg.Price) {
					then := strings.TrimSuffix(strings.TrimSpace(tg.Then), ".")
					if then != "" {
						then = " Then: " + then + "."
					}
					fire(fmt.Sprintf("tp%d", tg.Stage), "target", fmt.Sprintf("✅ %s · TP%d reached", t.Symbol, tg.Stage),
						fmt.Sprintf("Price %s hit TP%d %s: book %.0f%%.%s", p(price), tg.Stage, p(*tg.Price), tg.BookPercent, then), false)
				}
			}
		}
		for _, lv := range t.Levels {
			if lv.Price <= 0 || lv.Key == "" {
				continue
			}
			key := "lvl:" + lv.Key + ":" + ftoa(lv.Price)
			crossed := (lv.Above && price >= lv.Price) || (!lv.Above && price <= lv.Price)
			if crossed {
				fire(key, "level", lv.Title, strings.TrimSpace(lv.Body)+fmt.Sprintf(" Price %s.", p(price)), lv.Urgent)
			} else if risk > 0 && math.Abs(price-lv.Price) >= 0.5*risk {
				delete(m.Fired, key) // clearly back on the other side: alert again on the next cross
			}
		}
		if !t.CompleteBy.IsZero() && now.After(t.CompleteBy) {
			fire("time", "time", t.Symbol+" · time limit reached",
				fmt.Sprintf("The plan's complete-by date (%s) has passed. Close the trade or re-analyse.",
					t.CompleteBy.In(loc).Format("2 Jan")), false)
		}
		if risk > 0 && !stopHit {
			// Sharp move against the position: from the best price of the last hour to now.
			best := price
			for _, smp := range m.Samples {
				if now.Sub(smp.At) > suddenWindow {
					continue
				}
				if (long && smp.Price > best) || (!long && smp.Price < best) {
					best = smp.Price
				}
			}
			adverse := dir * (best - price) / risk
			if adverse >= s.SuddenMoveR {
				if last, ok := m.Fired["sudden"]; ok && now.Sub(last) >= suddenCooldown {
					delete(m.Fired, "sudden")
				}
				fire("sudden", "sudden", "⚡ "+t.Symbol+" · sharp move against you",
					fmt.Sprintf("−%.1fR within the last hour (%s → %s). Stop %s.", adverse, p(best), p(price), p(t.Stop)), true)
			}
			// Gap: the first check after a long pause (market closed) opened well against the position.
			if prevPrice > 0 && !prevAt.IsZero() && now.Sub(prevAt) >= gapPause {
				gap := dir * (prevPrice - price) / risk
				if gap >= 0.75 {
					fire("gap:"+now.In(loc).Format("2006-01-02"), "gap", t.Symbol+" · opened against you",
						fmt.Sprintf("Opened %.1fR against your position (%s → %s). Stop %s.", gap, p(prevPrice), p(price), p(t.Stop)), true)
				}
			}
		}
	}

	// Keep one hour of samples and forget day-specific keys after 30 days.
	kept := m.Samples[:0]
	for _, smp := range m.Samples {
		if now.Sub(smp.At) <= suddenWindow {
			kept = append(kept, smp)
		}
	}
	m.Samples = append(kept, Sample{At: now, Price: price})
	for k, at := range m.Fired {
		if (strings.HasPrefix(k, "gap:") || strings.HasPrefix(k, "lvl:")) && now.Sub(at) > 30*24*time.Hour {
			delete(m.Fired, k)
		}
	}
	m.LastPrice, m.LastCheck = price, now
	return out
}

// Summary builds the morning/evening digest for all watched trades.
func Summary(trades []WatchTrade, mem map[string]*Memory, now time.Time, loc *time.Location) (string, string) {
	sorted := append([]WatchTrade(nil), trades...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Status != sorted[j].Status {
			return sorted[i].Status == "open"
		}
		return sorted[i].Symbol < sorted[j].Symbol
	})
	open, upcoming := 0, 0
	var lines []string
	for _, t := range sorted {
		m := mem[t.ID]
		last := 0.0
		if m != nil {
			last = m.LastPrice
		}
		switch t.Status {
		case "open":
			open++
			if last > 0 && t.Risk() > 0 {
				dir := 1.0
				if !t.Long() {
					dir = -1
				}
				lines = append(lines, fmt.Sprintf("%s %s: %+.1fR at %s", t.Symbol, t.Side, dir*(last-t.Entry())/t.Risk(), money(last, t.Currency)))
			} else {
				lines = append(lines, fmt.Sprintf("%s %s: waiting for a price", t.Symbol, t.Side))
			}
		case "upcoming":
			upcoming++
			if last > 0 {
				edge := t.EntryLow
				if last > t.EntryHigh {
					edge = t.EntryHigh
				}
				if last >= t.EntryLow && last <= t.EntryHigh {
					lines = append(lines, fmt.Sprintf("%s: inside the entry zone", t.Symbol))
				} else {
					lines = append(lines, fmt.Sprintf("%s: %.1f%% from the entry zone", t.Symbol, (last/edge-1)*100))
				}
			}
		}
	}
	if len(lines) > 8 {
		lines = append(lines[:8], fmt.Sprintf("+%d more", len(lines)-8))
	}
	title := fmt.Sprintf("Third Eye · %d open, %d upcoming", open, upcoming)
	return title, strings.Join(lines, "\n")
}
