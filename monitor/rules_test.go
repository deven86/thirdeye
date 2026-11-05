package main

import (
	"strings"
	"testing"
	"time"
)

func f(v float64) *float64 { return &v }

// A long BTC plan: entry 99–101, stop 95 (R = 5), targets 105/110/115/120 + runner.
func longTrade(status string) WatchTrade {
	return WatchTrade{
		ID: "t1", Symbol: "BTC/USDT", Provider: "binance", ProviderKey: "BTCUSDT", Kind: "crypto", Currency: "USDT",
		Side: "long", Status: status, EntryLow: 99, EntryHigh: 101, Stop: 95, InitialStop: 95,
		Targets: []Target{
			{Stage: 1, Price: f(105), BookPercent: 30, Then: "Move stop to breakeven"},
			{Stage: 2, Price: f(110), BookPercent: 25, Then: "Trail stop to TP1"},
			{Stage: 3, Price: f(115), BookPercent: 20},
			{Stage: 4, Price: f(120), BookPercent: 15},
			{Stage: 5, BookPercent: 10},
		},
		CompleteBy: time.Date(2026, 12, 4, 0, 0, 0, 0, time.UTC), CadenceSeconds: 300,
	}
}

var t0 = time.Date(2026, 11, 5, 10, 0, 0, 0, time.UTC)

func kinds(al []Alert) string {
	var k []string
	for _, a := range al {
		k = append(k, a.Kind)
	}
	return strings.Join(k, ",")
}

func TestEntryZoneFiresOnceAndRearmsAfterLeaving(t *testing.T) {
	tr, m := longTrade("upcoming"), &Memory{}
	if got := kinds(Evaluate(tr, 103, t0, m, Settings{}, istZone)); got != "" {
		t.Fatalf("outside the zone: %q", got)
	}
	al := Evaluate(tr, 100, t0.Add(5*time.Minute), m, Settings{}, istZone)
	if kinds(al) != "entry" || !strings.Contains(al[0].Body, "99.00–101.00") || !strings.Contains(al[0].Body, "TP1 105.00") {
		t.Fatalf("entry alert: %+v", al)
	}
	if got := kinds(Evaluate(tr, 100.5, t0.Add(10*time.Minute), m, Settings{}, istZone)); got != "" {
		t.Fatalf("no repeat while still in the zone: %q", got)
	}
	Evaluate(tr, 102, t0.Add(15*time.Minute), m, Settings{}, istZone) // 1 above the zone = 0.2R: not re-armed
	if got := kinds(Evaluate(tr, 100, t0.Add(20*time.Minute), m, Settings{}, istZone)); got != "" {
		t.Fatalf("small wobble must not re-alert: %q", got)
	}
	Evaluate(tr, 104, t0.Add(25*time.Minute), m, Settings{}, istZone) // 3 above = 0.6R: re-armed
	if got := kinds(Evaluate(tr, 100, t0.Add(30*time.Minute), m, Settings{}, istZone)); got != "entry" {
		t.Fatalf("second visit after leaving clearly: %q", got)
	}
}

func TestUpcomingPastStopIsInvalidated(t *testing.T) {
	tr, m := longTrade("upcoming"), &Memory{}
	if got := kinds(Evaluate(tr, 94, t0, m, Settings{}, istZone)); got != "invalid" {
		t.Fatalf("got %q", got)
	}
}

func TestOpenLongStopNearStopAndTargets(t *testing.T) {
	tr := longTrade("open")
	tr.AvgEntry = f(100)
	m := &Memory{}
	if got := kinds(Evaluate(tr, 101, t0, m, Settings{}, istZone)); got != "" {
		t.Fatalf("quiet: %q", got)
	}
	al := Evaluate(tr, 96, t0.Add(5*time.Minute), m, Settings{SuddenMoveR: 9}, istZone)
	if kinds(al) != "near-stop" || !al[0].Urgent {
		t.Fatalf("0.2R from the stop: %+v", al)
	}
	al = Evaluate(tr, 95, t0.Add(6*time.Minute), m, Settings{SuddenMoveR: 9}, istZone)
	if kinds(al) != "stop" || !al[0].Urgent || !strings.Contains(al[0].Body, "-1.0R") {
		t.Fatalf("stop: %+v", al)
	}
	if got := kinds(Evaluate(tr, 94, t0.Add(7*time.Minute), m, Settings{SuddenMoveR: 9}, istZone)); got != "" {
		t.Fatalf("stop fires once: %q", got)
	}

	m2 := &Memory{}
	al = Evaluate(tr, 111, t0, m2, Settings{}, istZone)
	if kinds(al) != "target,target" {
		t.Fatalf("a jump through TP1 and TP2 reports both: %q", kinds(al))
	}
	if !strings.Contains(al[0].Body, "book 30%. Then: Move stop to breakeven.") {
		t.Fatalf("tp1 text: %s", al[0].Body)
	}
	// TP1 recorded in the app → booked → never again.
	tr.Targets[0].Booked = true
	tr.Stop = 100 // stop moved to breakeven: plan changed → stop alerts re-armed
	if got := kinds(Evaluate(tr, 112, t0.Add(time.Minute), m2, Settings{}, istZone)); got != "" {
		t.Fatalf("nothing new: %q", got)
	}
	if got := kinds(Evaluate(tr, 100, t0.Add(2*time.Minute), m2, Settings{SuddenMoveR: 9}, istZone)); got != "stop" {
		t.Fatalf("new breakeven stop: %q", got)
	}
}

func TestShortMirrors(t *testing.T) {
	tr := WatchTrade{ID: "s", Symbol: "ETH/USDT", Side: "short", Status: "open", EntryLow: 99, EntryHigh: 101, Stop: 105,
		InitialStop: 105, AvgEntry: f(100), Targets: []Target{{Stage: 1, Price: f(95), BookPercent: 30}}, Currency: "USDT"}
	m := &Memory{}
	if got := kinds(Evaluate(tr, 94.9, t0, m, Settings{}, istZone)); got != "target" {
		t.Fatalf("short TP: %q", got)
	}
	if got := kinds(Evaluate(tr, 105.2, t0.Add(time.Minute), m, Settings{SuddenMoveR: 99}, istZone)); got != "stop" {
		t.Fatalf("short stop: %q", got)
	}
}

func TestSuddenMoveAndCooldown(t *testing.T) {
	tr := longTrade("open")
	tr.AvgEntry = f(100)
	tr.Stop, tr.InitialStop = 90, 90 // R = 10
	m := &Memory{}
	Evaluate(tr, 110, t0, m, Settings{}, istZone)
	Evaluate(tr, 108, t0.Add(10*time.Minute), m, Settings{}, istZone)
	al := Evaluate(tr, 99.5, t0.Add(20*time.Minute), m, Settings{}, istZone) // 110 → 99.5 = 1.05R in 20 min
	if kinds(al) != "sudden" || !strings.Contains(al[0].Body, "−1.1R") {
		t.Fatalf("sudden: %+v", al)
	}
	Evaluate(tr, 110, t0.Add(30*time.Minute), m, Settings{}, istZone)
	if got := kinds(Evaluate(tr, 99, t0.Add(40*time.Minute), m, Settings{}, istZone)); got != "" {
		t.Fatalf("cooldown: %q", got)
	}
	Evaluate(tr, 110, t0.Add(3*time.Hour), m, Settings{}, istZone)
	if got := kinds(Evaluate(tr, 99, t0.Add(3*time.Hour+10*time.Minute), m, Settings{}, istZone)); got != "sudden" {
		t.Fatalf("after cooldown: %q", got)
	}
}

func TestGapAfterClosedMarket(t *testing.T) {
	tr := longTrade("open")
	tr.AvgEntry = f(100)
	m := &Memory{}
	Evaluate(tr, 102, t0, m, Settings{SuddenMoveR: 99}, istZone)
	al := Evaluate(tr, 98, t0.Add(18*time.Hour), m, Settings{SuddenMoveR: 99}, istZone) // 102 → 98 = 0.8R overnight
	if kinds(al) != "gap" {
		t.Fatalf("gap: %q", kinds(al))
	}
}

func TestTimeLimitAndExpiry(t *testing.T) {
	up := longTrade("upcoming")
	late := up.CompleteBy.Add(time.Hour)
	if got := kinds(Evaluate(up, 110, late, &Memory{}, Settings{}, istZone)); got != "expired" {
		t.Fatalf("upcoming past date: %q", got)
	}
	open := longTrade("open")
	open.AvgEntry = f(100)
	if got := kinds(Evaluate(open, 102, late, &Memory{}, Settings{}, istZone)); got != "time" {
		t.Fatalf("open past date: %q", got)
	}
}

func TestSummary(t *testing.T) {
	a := longTrade("open")
	a.AvgEntry = f(100)
	b := longTrade("upcoming")
	b.ID, b.Symbol = "t2", "ETH/USDT"
	mem := map[string]*Memory{"t1": {LastPrice: 102.5}, "t2": {LastPrice: 103.02}}
	title, body := Summary([]WatchTrade{b, a}, mem, t0, istZone)
	if title != "Third Eye · 1 open, 1 upcoming" {
		t.Fatalf("title %q", title)
	}
	if body != "BTC/USDT long: +0.5R at 102.50\nETH/USDT: 2.0% from the entry zone" {
		t.Fatalf("body %q", body)
	}
}

func TestMoneyFormatting(t *testing.T) {
	cases := map[string]string{
		money(78280.01, "USDT"):  "78,280.01",
		money(1234567.5, "INR"):  "12,34,567.50",
		money(2731.5, "INR"):     "2,731.50",
		money(0.00001234, "USD"): "0.00001",
		money(5.12345, "USD"):    "5.1235",
		money(-1500, "USD"):      "-1,500.00",
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("got %q want %q", got, want)
		}
	}
}

func TestLevelCrossFiresOnceAndRearms(t *testing.T) {
	loc := time.UTC
	now := time.Date(2026, 11, 5, 10, 0, 0, 0, loc)
	avg := 100.0
	tr := WatchTrade{ID: "x", Symbol: "ABC", Side: "long", Status: "open", Currency: "INR", EntryLow: 99, EntryHigh: 101,
		Stop: 90, InitialStop: 90, AvgEntry: &avg, OpenQuantity: 10,
		Levels: []Level{{Key: "support", Price: 95, Above: false, Title: "support broken", Body: "Below support.", Urgent: true}}}
	m := &Memory{}
	if a := Evaluate(tr, 97, now, m, Settings{}, loc); len(levelAlerts(a)) != 0 {
		t.Fatalf("no cross yet: %v", a)
	}
	a := Evaluate(tr, 94.5, now.Add(5*time.Minute), m, Settings{}, loc)
	if got := levelAlerts(a); len(got) != 1 || !got[0].Urgent {
		t.Fatalf("expected one urgent level alert, got %v", a)
	}
	if a := Evaluate(tr, 94, now.Add(10*time.Minute), m, Settings{}, loc); len(levelAlerts(a)) != 0 {
		t.Fatalf("must not repeat: %v", a)
	}
	Evaluate(tr, 101, now.Add(3*time.Hour), m, Settings{}, loc) // 6 away = 0.6R: re-armed
	if a := Evaluate(tr, 94.9, now.Add(4*time.Hour), m, Settings{}, loc); len(levelAlerts(a)) != 1 {
		t.Fatalf("expected re-arm after moving back: %v", a)
	}
}

func levelAlerts(a []Alert) []Alert {
	var out []Alert
	for _, x := range a {
		if x.Kind == "level" {
			out = append(out, x)
		}
	}
	return out
}
