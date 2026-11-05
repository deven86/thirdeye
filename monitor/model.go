package main

import (
	"math"
	"time"
)

// WatchTrade is what the iPhone app sends for every upcoming or open trade.
type WatchTrade struct {
	ID             string    `json:"id"`
	Symbol         string    `json:"symbol"`
	Provider       string    `json:"provider"` // binance | twelveData | upstox
	ProviderKey    string    `json:"providerKey"`
	Exchange       string    `json:"exchange"`
	Segment        string    `json:"segment"`
	Kind           string    `json:"kind"` // crypto, equity, etf, index, future, option, forex, commodity
	Currency       string    `json:"currency"`
	Side           string    `json:"side"`   // long | short
	Status         string    `json:"status"` // upcoming | open
	Mode           string    `json:"mode"`   // paper | real
	EntryLow       float64   `json:"entryLow"`
	EntryHigh      float64   `json:"entryHigh"`
	Stop           float64   `json:"stop"` // current stop (moves up after TP1)
	InitialStop    float64   `json:"initialStop"`
	AvgEntry       *float64  `json:"avgEntry,omitempty"`
	OpenQuantity   float64   `json:"openQuantity"`
	Targets        []Target  `json:"targets"`
	Levels         []Level   `json:"levels,omitempty"` // key chart levels from the analysis (trade watch)
	CompleteBy     time.Time `json:"completeBy"`
	CadenceSeconds int       `json:"cadenceSeconds"`
	UpdatedAt      time.Time `json:"updatedAt"`
}

// Target is one take-profit step of the plan.
type Target struct {
	Stage       int      `json:"stage"`
	Price       *float64 `json:"price,omitempty"` // nil = trailing runner
	R           *float64 `json:"r,omitempty"`
	BookPercent float64  `json:"bookPercent"`
	Then        string   `json:"then"`
	Booked      bool     `json:"booked"` // the user already recorded this exit
}

// Level is a chart level the trade's reasons rest on. Crossing it fires one alert.
type Level struct {
	Key    string  `json:"key"`
	Price  float64 `json:"price"`
	Above  bool    `json:"above"` // fire when the price is at or above Price (otherwise at or below)
	Title  string  `json:"title"`
	Body   string  `json:"body"`
	Urgent bool    `json:"urgent"`
}

func (t WatchTrade) Long() bool { return t.Side != "short" }

// Entry is the average fill of an open trade, otherwise the middle of the entry zone.
func (t WatchTrade) Entry() float64 {
	if t.AvgEntry != nil && *t.AvgEntry > 0 {
		return *t.AvgEntry
	}
	return (t.EntryLow + t.EntryHigh) / 2
}

// Risk is one R in price units: entry to the initial stop.
func (t WatchTrade) Risk() float64 {
	stop := t.InitialStop
	if stop == 0 {
		stop = t.Stop
	}
	return math.Abs(t.Entry() - stop)
}

// Cadence is how often the trade is checked while its market is open.
func (t WatchTrade) Cadence() time.Duration {
	s := t.CadenceSeconds
	if s <= 0 {
		s = 300
	}
	if s < 20 {
		s = 20
	}
	return time.Duration(s) * time.Second
}

// Fingerprint changes when the plan changes in a way that should re-arm alerts (stop moved, entered, ...).
func (t WatchTrade) Fingerprint() string {
	return t.Status + "|" + t.Side + "|" + ftoa(t.Stop) + "|" + ftoa(t.EntryLow) + "|" + ftoa(t.EntryHigh)
}

// Settings the app can change.
type Settings struct {
	SuddenMoveR  float64  `json:"suddenMoveR"`  // adverse move within an hour that triggers an alert, in R (default 1)
	SummaryTimes []string `json:"summaryTimes"` // "09:00", "21:00" in TimeZone
	TimeZone     string   `json:"timeZone"`     // default Asia/Kolkata
}

func (s Settings) withDefaults() Settings {
	if s.SuddenMoveR <= 0 {
		s.SuddenMoveR = 1
	}
	if s.SummaryTimes == nil {
		s.SummaryTimes = []string{"09:00", "21:00"}
	}
	if s.TimeZone == "" {
		s.TimeZone = "Asia/Kolkata"
	}
	return s
}

// Device is one iPhone/iPad that receives push notifications.
type Device struct {
	InstallID   string    `json:"installID"` // stable per app install (identifierForVendor)
	Token       string    `json:"token"`
	Environment string    `json:"environment"` // production | development
	Name        string    `json:"name"`
	TeamID      string    `json:"teamID"`
	BundleID    string    `json:"bundleID"`
	UpdatedAt   time.Time `json:"updatedAt"`
	LastError   string    `json:"lastError,omitempty"`
}

// Alert is one notification (also kept in the history the app shows).
type Alert struct {
	ID        string    `json:"id"`
	TradeID   string    `json:"tradeID,omitempty"`
	Symbol    string    `json:"symbol,omitempty"`
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	Body      string    `json:"body"`
	Urgent    bool      `json:"urgent"` // delivered as time-sensitive (breaks through Focus)
	Price     float64   `json:"price,omitempty"`
	At        time.Time `json:"at"`
	Delivered string    `json:"delivered,omitempty"`
}
