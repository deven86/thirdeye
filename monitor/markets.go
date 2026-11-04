package main

import (
	"strings"
	"time"
	_ "time/tzdata" // Windows has no zoneinfo database; embed it
)

var (
	istZone = mustZone("Asia/Kolkata")
	nyZone  = mustZone("America/New_York")
)

func mustZone(name string) *time.Location {
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return loc
}

// clock returns minutes since midnight for "HH:MM".
func clock(hhmm string) int {
	var h, m int
	if len(hhmm) == 5 {
		h = int(hhmm[0]-'0')*10 + int(hhmm[1]-'0')
		m = int(hhmm[3]-'0')*10 + int(hhmm[4]-'0')
	}
	return h*60 + m
}

func weekdaySession(now time.Time, loc *time.Location, open, close string) bool {
	t := now.In(loc)
	if t.Weekday() == time.Saturday || t.Weekday() == time.Sunday {
		return false
	}
	minutes := t.Hour()*60 + t.Minute()
	return minutes >= clock(open) && minutes < clock(close)
}

// MarketOpen says whether the product trades right now (exchange holidays are not modelled:
// on a holiday the price simply doesn't change and no alert fires).
func MarketOpen(t WatchTrade, now time.Time) bool {
	switch t.Provider {
	case "binance":
		return true
	case "twelveData":
		if t.Kind == "forex" || t.Kind == "commodity" {
			// FX and spot metals: Sunday 17:00 to Friday 17:00 New York time.
			n := now.In(nyZone)
			minutes := n.Hour()*60 + n.Minute()
			switch n.Weekday() {
			case time.Saturday:
				return false
			case time.Sunday:
				return minutes >= 17*60
			case time.Friday:
				return minutes < 17*60
			default:
				return true
			}
		}
		return weekdaySession(now, nyZone, "09:30", "16:00") // US cash session
	case "upstox":
		seg := strings.ToUpper(t.Segment + " " + t.Exchange)
		switch {
		case strings.Contains(seg, "MCX"):
			return weekdaySession(now, istZone, "09:00", "23:55")
		case strings.Contains(seg, "CD_FO") || strings.Contains(seg, "NCD") || strings.Contains(seg, "BCD"):
			return weekdaySession(now, istZone, "09:00", "17:00")
		default:
			return weekdaySession(now, istZone, "09:15", "15:30")
		}
	}
	return true
}
