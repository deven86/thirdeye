package main

import (
	"testing"
	"time"
)

func at(loc *time.Location, y int, mo time.Month, d, h, mi int) time.Time {
	return time.Date(y, mo, d, h, mi, 0, 0, loc)
}

func TestMarketHours(t *testing.T) {
	nse := WatchTrade{Provider: "upstox", Exchange: "NSE", Segment: "NSE_EQ"}
	mcx := WatchTrade{Provider: "upstox", Exchange: "MCX", Segment: "MCX_FO"}
	us := WatchTrade{Provider: "twelveData", Kind: "equity"}
	fx := WatchTrade{Provider: "twelveData", Kind: "forex"}
	btc := WatchTrade{Provider: "binance"}
	cases := []struct {
		name string
		t    WatchTrade
		when time.Time
		open bool
	}{
		{"NSE Thursday 10:00 IST", nse, at(istZone, 2026, 11, 5, 10, 0), true},
		{"NSE before open", nse, at(istZone, 2026, 11, 5, 9, 10), false},
		{"NSE after close", nse, at(istZone, 2026, 11, 5, 15, 30), false},
		{"NSE Saturday", nse, at(istZone, 2026, 11, 7, 11, 0), false},
		{"MCX evening", mcx, at(istZone, 2026, 11, 5, 22, 0), true},
		{"US 10:00 New York", us, at(nyZone, 2026, 11, 5, 10, 0), true},
		{"US 16:00 closed", us, at(nyZone, 2026, 11, 5, 16, 0), false},
		{"FX Sunday 16:59 NY closed", fx, at(nyZone, 2026, 11, 8, 16, 59), false},
		{"FX Sunday 17:00 NY open", fx, at(nyZone, 2026, 11, 8, 17, 0), true},
		{"FX Friday 17:00 NY closed", fx, at(nyZone, 2026, 11, 6, 17, 0), false},
		{"FX Wednesday night", fx, at(nyZone, 2026, 11, 4, 23, 0), true},
		{"crypto Sunday", btc, at(time.UTC, 2026, 11, 8, 3, 0), true},
	}
	for _, c := range cases {
		if got := MarketOpen(c.t, c.when); got != c.open {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func TestUpstoxExpiry(t *testing.T) {
	issued := at(istZone, 2026, 11, 5, 9, 0)
	if got := upstoxExpiry(issued); !got.Equal(at(istZone, 2026, 11, 6, 3, 30)) {
		t.Fatalf("morning login ends next day 03:30, got %v", got)
	}
	early := at(istZone, 2026, 11, 5, 2, 0)
	if got := upstoxExpiry(early); !got.Equal(at(istZone, 2026, 11, 5, 3, 30)) {
		t.Fatalf("02:00 login ends at 03:30 same day, got %v", got)
	}
}
