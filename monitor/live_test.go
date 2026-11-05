package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func liveTrade() WatchTrade {
	avg := 100.0
	tp1, tp2 := 110.0, 120.0
	return WatchTrade{ID: "t1", Symbol: "ABC", Side: "long", Status: "open", Currency: "USD", EntryLow: 99, EntryHigh: 101,
		Stop: 90, InitialStop: 90, AvgEntry: &avg, OpenQuantity: 10,
		Targets: []Target{{Stage: 1, Price: &tp1, BookPercent: 30}, {Stage: 2, Price: &tp2, BookPercent: 25}}}
}

func TestLiveStateForAnOpenLong(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	s := BuildLiveState(liveTrade(), 105, now)
	if s.Status != "open" || s.R == nil || *s.R != 0.5 || *s.NextTargetStage != 1 {
		t.Fatalf("state %+v", s)
	}
	if s.Progress != 0.75 { // (105−90)/(110−90)
		t.Fatalf("progress %v", s.Progress)
	}
	if st := BuildLiveState(liveTrade(), 111, now); st.Status != "target" || !strings.Contains(st.Note, "TP1") {
		t.Fatalf("target %+v", st)
	}
	if st := BuildLiveState(liveTrade(), 92, now); st.Status != "nearStop" {
		t.Fatalf("near stop %+v", st)
	}
	if st := BuildLiveState(liveTrade(), 89, now); st.Status != "stop" || st.Progress != 0 {
		t.Fatalf("stop %+v", st)
	}
	tr := liveTrade()
	tr.Targets[0].Booked = true
	if st := BuildLiveState(tr, 111, now); *st.NextTargetStage != 2 || st.Status != "open" {
		t.Fatalf("after TP1 booked %+v", st)
	}
}

func TestLiveStateWhileWaitingForEntry(t *testing.T) {
	tr := liveTrade()
	tr.Status, tr.AvgEntry = "upcoming", nil
	if st := BuildLiveState(tr, 100, time.Now()); st.Status != "inZone" || st.R != nil {
		t.Fatalf("%+v", st)
	}
	if st := BuildLiveState(tr, 103.02, time.Now()); st.Status != "waiting" || !strings.Contains(st.Note, "2.0%") {
		t.Fatalf("%+v", st)
	}
}

func TestDecideLiveThrottlesButNeverDelaysAStatusChange(t *testing.T) {
	now := time.Now()
	la := LiveActivity{LastStatus: "open", LastSent: now.Add(-30 * time.Second), LastPrice: 100}
	if d := DecideLive(la, LiveState{Status: "open", Price: 101}, now); d.Send {
		t.Fatal("within a minute: wait")
	}
	if d := DecideLive(la, LiveState{Status: "stop", Price: 89}, now); !d.Send || d.Priority != 10 || !d.Alert {
		t.Fatalf("stop must go now with an alert: %+v", d)
	}
	la.LastSent = now.Add(-2 * time.Minute)
	if d := DecideLive(la, LiveState{Status: "open", Price: 101}, now); !d.Send || d.Priority != 5 {
		t.Fatalf("%+v", d)
	}
	if d := DecideLive(la, LiveState{Status: "open", Price: 100}, now); d.Send {
		t.Fatal("same price: nothing to send")
	}
}

func TestLivePayloadShape(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var v struct {
		APS struct {
			Event        string          `json:"event"`
			Timestamp    int64           `json:"timestamp"`
			ContentState json.RawMessage `json:"content-state"`
			Alert        map[string]string
		} `json:"aps"`
	}
	b := LivePayload(BuildLiveState(liveTrade(), 105, now), "update", false, "ABC", now)
	if err := json.Unmarshal(b, &v); err != nil || v.APS.Event != "update" || v.APS.Timestamp != now.Unix() {
		t.Fatalf("%s", b)
	}
	if !strings.Contains(string(v.APS.ContentState), `"progress":0.75`) || !strings.Contains(string(v.APS.ContentState), `"updatedAt":1800000000`) {
		t.Fatalf("%s", v.APS.ContentState)
	}
}

func TestTickPushesLiveActivityAndDropsGoneTokens(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	mon := NewMonitor(store, t.TempDir(), t.TempDir())
	tr := liveTrade()
	tr.Provider, tr.ProviderKey = "binance", "ABCUSDT"
	mon.store.S.Watch = []WatchTrade{tr}
	mon.store.S.LiveActivities["t1"] = &LiveActivity{TradeID: "t1", Token: strings.Repeat("a", 64), StartedAt: time.Now()}
	mon.fetch = func(_ context.Context, _ string, _ []string, _ string) (map[string]float64, error) {
		return map[string]float64{"ABCUSDT": 105}, nil
	}
	var got []string
	mon.sendLive = func(_ context.Context, la LiveActivity, body []byte, pr int, _ time.Time) error {
		got = append(got, string(body))
		return nil
	}
	mon.send = func(context.Context, Device, Alert, time.Time) error { return nil }
	mon.Tick(context.Background(), time.Now())
	if len(got) != 1 || mon.store.S.LiveActivities["t1"].LastStatus != "open" {
		t.Fatalf("pushes %v, la %+v", got, mon.store.S.LiveActivities["t1"])
	}
	mon.sendLive = func(context.Context, LiveActivity, []byte, int, time.Time) error { return ErrDeviceGone }
	mon.fetch = func(_ context.Context, _ string, _ []string, _ string) (map[string]float64, error) {
		return map[string]float64{"ABCUSDT": 89}, nil
	}
	mon.Tick(context.Background(), time.Now().Add(10*time.Minute))
	if _, ok := mon.store.S.LiveActivities["t1"]; ok {
		t.Fatal("a gone token must be dropped")
	}
}

func TestLiveStateMoneyIncludesLotsAndBookedProfit(t *testing.T) {
	tr := liveTrade() // long 10 @ 100
	tr.ContractSize, tr.Realized = 100, 50
	s := BuildLiveState(tr, 105, time.Now())
	if s.Pnl == nil || *s.Pnl != 50+5*10*100 {
		t.Fatalf("pnl %v", s.Pnl)
	}
}
