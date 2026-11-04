package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Monitor runs the price loop and owns the push sender.
type Monitor struct {
	store     *Store
	dataDir   string
	exeDir    string
	startedAt time.Time

	mu         sync.Mutex
	lastLoopAt time.Time
	providers  map[string]string // provider → "ok 14:31" or the last error
	twelveLog  []time.Time       // Twelve Data symbol requests in the last minute (free plan: 8)
	apns       *APNs
	apnsErr    string

	// Overridable for tests.
	fetch func(ctx context.Context, provider string, keys []string, secret string) (map[string]float64, error)
	send  func(ctx context.Context, d Device, al Alert, now time.Time) error
}

func NewMonitor(store *Store, dataDir, exeDir string) *Monitor {
	m := &Monitor{store: store, dataDir: dataDir, exeDir: exeDir, startedAt: time.Now(), providers: map[string]string{}}
	m.fetch = defaultFetch
	m.send = m.sendAPNs
	return m
}

func defaultFetch(ctx context.Context, provider string, keys []string, secret string) (map[string]float64, error) {
	switch provider {
	case "binance":
		return BinancePrices(ctx, keys)
	case "twelveData":
		return TwelveDataPrices(ctx, secret, keys)
	case "upstox":
		return UpstoxPrices(ctx, secret, keys)
	}
	return nil, fmt.Errorf("unknown provider %q", provider)
}

// upstoxExpiry: Upstox tokens end at the next 03:30 IST after login.
func upstoxExpiry(issued time.Time) time.Time {
	t := issued.In(istZone)
	cut := time.Date(t.Year(), t.Month(), t.Day(), 3, 30, 0, 0, istZone)
	if !cut.After(t) {
		cut = cut.AddDate(0, 0, 1)
	}
	return cut
}

// Run checks due trades every 5 seconds until ctx ends.
func (m *Monitor) Run(ctx context.Context) {
	m.importAPNsKey()
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	keyScan := time.NewTicker(time.Minute)
	defer keyScan.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-keyScan.C:
			m.importAPNsKey()
		case <-tick.C:
			m.safeTick(ctx, time.Now())
		}
	}
}

func (m *Monitor) safeTick(ctx context.Context, now time.Time) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("check failed: %v", r)
		}
	}()
	m.Tick(ctx, now)
}

// Tick runs one round: fetch prices for due trades, evaluate rules, send alerts, summaries and reminders.
func (m *Monitor) Tick(ctx context.Context, now time.Time) {
	st := m.store
	st.Lock()
	settings := st.S.Settings.withDefaults()
	loc, err := time.LoadLocation(settings.TimeZone)
	if err != nil {
		loc = istZone
	}
	byProvider := map[string][]WatchTrade{}
	upstoxNeeded := false
	for _, t := range st.S.Watch {
		if t.Provider == "upstox" {
			upstoxNeeded = true
		}
		if !MarketOpen(t, now) {
			continue
		}
		mem := st.S.Memory[t.ID]
		interval := t.Cadence()
		if mem != nil && mem.LastPrice > 0 && t.Status == "open" && t.Risk() > 0 {
			dir := 1.0
			if !t.Long() {
				dir = -1
			}
			if dir*(mem.LastPrice-t.Stop)/t.Risk() <= 0.5 && interval > time.Minute {
				interval = time.Minute // close to the stop: look every minute
			}
		}
		if mem == nil || now.Sub(mem.LastCheck) >= interval {
			byProvider[t.Provider] = append(byProvider[t.Provider], t)
		}
	}
	twelveKey := st.Secret("twelveDataKey")
	upstoxToken := st.Secret("upstoxToken")
	if upstoxToken != "" && !st.S.UpstoxIssued.IsZero() && now.After(upstoxExpiry(st.S.UpstoxIssued)) {
		upstoxToken = ""
	}
	st.Unlock()

	// Fetch outside the lock.
	prices := map[string]float64{} // provider|key → price
	for provider, trades := range byProvider {
		keys := uniqueKeys(trades)
		secret := ""
		switch provider {
		case "twelveData":
			secret = twelveKey
			keys = m.twelveBudget(keys, now)
			if len(keys) == 0 {
				continue
			}
		case "upstox":
			secret = upstoxToken
		}
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		got, err := m.fetch(cctx, provider, keys, secret)
		cancel()
		m.mu.Lock()
		if err != nil {
			m.providers[provider] = err.Error()
		} else {
			m.providers[provider] = "ok " + now.In(loc).Format("15:04")
		}
		m.mu.Unlock()
		for k, v := range got {
			prices[provider+"|"+k] = v
		}
	}

	st.Lock()
	var alerts []Alert
	for provider, trades := range byProvider {
		for _, t := range trades {
			price, ok := prices[provider+"|"+t.ProviderKey]
			if !ok || price <= 0 {
				continue
			}
			mem := st.S.Memory[t.ID]
			if mem == nil {
				mem = &Memory{}
				st.S.Memory[t.ID] = mem
			}
			alerts = append(alerts, Evaluate(t, price, now, mem, settings, loc)...)
		}
	}
	// Morning/evening digest, within 30 minutes after each configured time.
	if len(st.S.Watch) > 0 {
		local := now.In(loc)
		today := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
		for _, hhmm := range settings.SummaryTimes {
			at := today.Add(time.Duration(clock(hhmm)) * time.Minute)
			if local.Before(at) || local.Sub(at) > 30*time.Minute || !st.S.LastSummary[hhmm].Before(today) {
				continue
			}
			st.S.LastSummary[hhmm] = local
			title, body := Summary(st.S.Watch, st.S.Memory, now, loc)
			alerts = append(alerts, Alert{ID: newID(), Kind: "summary", Title: title, Body: body, At: now})
		}
	}
	// Upstox reminder: once a day, around the India open, if an India trade can't be watched.
	if upstoxNeeded && upstoxToken == "" {
		local := now.In(loc)
		if wd := local.Weekday(); wd != time.Saturday && wd != time.Sunday {
			minutes := local.Hour()*60 + local.Minute()
			if minutes >= 8*60+45 && minutes <= 15*60+30 && !sameDay(st.S.LastLoginNag, now, loc) {
				st.S.LastLoginNag = now
				alerts = append(alerts, Alert{ID: newID(), Kind: "login", Title: "Third Eye · Upstox login needed",
					Body: "Open Third Eye and log in to Upstox so your PC can keep watching your India trades today.", At: now})
			}
		}
	}
	devices := append([]Device(nil), st.S.Devices...)
	st.Unlock()

	if len(alerts) > 0 {
		m.deliver(ctx, devices, alerts, now)
	}
	m.mu.Lock()
	m.lastLoopAt = now
	m.mu.Unlock()
	st.Lock()
	st.AddAlerts(alerts)
	if err := st.Save(); err != nil {
		log.Printf("save: %v", err)
	}
	st.Unlock()
}

func sameDay(a, b time.Time, loc *time.Location) bool {
	if a.IsZero() {
		return false
	}
	return a.In(loc).Format("2006-01-02") == b.In(loc).Format("2006-01-02")
}

func uniqueKeys(trades []WatchTrade) []string {
	seen := map[string]bool{}
	var keys []string
	for _, t := range trades {
		if t.ProviderKey != "" && !seen[t.ProviderKey] {
			seen[t.ProviderKey] = true
			keys = append(keys, t.ProviderKey)
		}
	}
	sort.Strings(keys)
	return keys
}

// twelveBudget keeps Twelve Data within 8 symbols per rolling minute (free plan).
func (m *Monitor) twelveBudget(keys []string, now time.Time) []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	kept := m.twelveLog[:0]
	for _, t := range m.twelveLog {
		if now.Sub(t) < time.Minute {
			kept = append(kept, t)
		}
	}
	m.twelveLog = kept
	room := 8 - len(m.twelveLog)
	if room <= 0 {
		return nil
	}
	if len(keys) > room {
		keys = keys[:room]
	}
	for range keys {
		m.twelveLog = append(m.twelveLog, now)
	}
	return keys
}

// deliver pushes every alert to every device and records the outcome on the alert.
func (m *Monitor) deliver(ctx context.Context, devices []Device, alerts []Alert, now time.Time) {
	var gone []string
	for i := range alerts {
		if len(devices) == 0 {
			alerts[i].Delivered = "not sent: no iPhone connected yet"
			continue
		}
		sent, errs := 0, []string{}
		for _, d := range devices {
			cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			err := m.send(cctx, d, alerts[i], now)
			cancel()
			switch {
			case err == nil:
				sent++
			case errors.Is(err, ErrDeviceGone):
				gone = append(gone, d.Token)
				errs = append(errs, err.Error())
			default:
				errs = append(errs, err.Error())
			}
		}
		if sent > 0 {
			alerts[i].Delivered = fmt.Sprintf("sent to %d device(s)", sent)
		} else {
			alerts[i].Delivered = "not sent: " + strings.Join(errs, "; ")
		}
		log.Printf("alert %s %s: %s — %s", alerts[i].Kind, alerts[i].Symbol, alerts[i].Title, alerts[i].Delivered)
	}
	if len(gone) > 0 {
		m.store.Lock()
		kept := m.store.S.Devices[:0]
		for _, d := range m.store.S.Devices {
			drop := false
			for _, g := range gone {
				if d.Token == g {
					drop = true
				}
			}
			if !drop {
				kept = append(kept, d)
			}
		}
		m.store.S.Devices = kept
		m.store.Unlock()
	}
}

// sendAPNs builds the APNs sender lazily from the imported key and the team ID the app reported.
func (m *Monitor) sendAPNs(ctx context.Context, d Device, al Alert, now time.Time) error {
	m.mu.Lock()
	sender := m.apns
	m.mu.Unlock()
	if sender == nil || sender.TeamID != d.TeamID {
		m.store.Lock()
		pemKey, keyID := m.store.Secret("apnsKey"), m.store.S.APNsKeyID
		m.store.Unlock()
		if pemKey == "" {
			return errors.New("no APNs key yet — put AuthKey_XXXXXXXXXX.p8 next to thirdeye-monitor.exe")
		}
		if d.TeamID == "" {
			return errors.New("the app has not reported its team ID yet — open Third Eye once")
		}
		key, err := ParseP8([]byte(pemKey))
		if err != nil {
			return fmt.Errorf("APNs key unreadable: %w", err)
		}
		sender = &APNs{KeyID: keyID, TeamID: d.TeamID, Key: key}
		m.mu.Lock()
		m.apns = sender
		m.mu.Unlock()
	}
	return sender.Send(ctx, d, al, now)
}

// importAPNsKey looks for AuthKey_<KEYID>.p8 next to the program or in the data folder, stores it
// encrypted and renames the file so it is not imported twice.
func (m *Monitor) importAPNsKey() {
	for _, dir := range []string{m.exeDir, m.dataDir} {
		if dir == "" {
			continue
		}
		matches, _ := filepath.Glob(filepath.Join(dir, "AuthKey_*.p8"))
		for _, path := range matches {
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			if _, err := ParseP8(data); err != nil {
				m.setAPNsErr("AuthKey file is not a valid .p8 key: " + err.Error())
				continue
			}
			keyID := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "AuthKey_"), ".p8")
			m.store.Lock()
			err = m.store.SetSecret("apnsKey", string(data))
			if err == nil {
				m.store.S.APNsKeyID = keyID
				err = m.store.Save()
			}
			m.store.Unlock()
			if err != nil {
				m.setAPNsErr("could not store the APNs key: " + err.Error())
				continue
			}
			_ = os.Rename(path, path+".imported")
			m.mu.Lock()
			m.apns, m.apnsErr = nil, ""
			m.mu.Unlock()
			log.Printf("imported APNs key %s", keyID)
		}
	}
}

func (m *Monitor) setAPNsErr(s string) {
	m.mu.Lock()
	m.apnsErr = s
	m.mu.Unlock()
	log.Print(s)
}

// TradeStatus is one row of the status the app shows.
type TradeStatus struct {
	ID         string    `json:"id"`
	Symbol     string    `json:"symbol"`
	LastPrice  float64   `json:"lastPrice,omitempty"`
	LastCheck  time.Time `json:"lastCheck,omitempty"`
	MarketOpen bool      `json:"marketOpen"`
}

// StatusResponse is GET /v1/status.
type StatusResponse struct {
	Version    string            `json:"version"`
	StartedAt  time.Time         `json:"startedAt"`
	Now        time.Time         `json:"now"`
	LastLoopAt time.Time         `json:"lastLoopAt"`
	Watching   int               `json:"watching"`
	APNs       string            `json:"apns"`
	Devices    int               `json:"devices"`
	Providers  map[string]string `json:"providers"`
	Trades     []TradeStatus     `json:"trades"`
	Alerts     []Alert           `json:"alerts"`
}

func (m *Monitor) Status(now time.Time) StatusResponse {
	m.store.Lock()
	s := StatusResponse{Version: version, StartedAt: m.startedAt, Now: now, Watching: len(m.store.S.Watch),
		Devices: len(m.store.S.Devices), Providers: map[string]string{}}
	hasKey := m.store.S.Secrets["apnsKey"] != ""
	for _, t := range m.store.S.Watch {
		ts := TradeStatus{ID: t.ID, Symbol: t.Symbol, MarketOpen: MarketOpen(t, now)}
		if mem := m.store.S.Memory[t.ID]; mem != nil {
			ts.LastPrice, ts.LastCheck = mem.LastPrice, mem.LastCheck
		}
		s.Trades = append(s.Trades, ts)
	}
	n := len(m.store.S.Alerts)
	if n > 30 {
		n = 30
	}
	s.Alerts = append([]Alert(nil), m.store.S.Alerts[:n]...)
	teamKnown := false
	for _, d := range m.store.S.Devices {
		if d.TeamID != "" {
			teamKnown = true
		}
	}
	twelve, upstox := m.store.Secret("twelveDataKey") != "", m.store.Secret("upstoxToken") != ""
	upstoxValid := upstox && !m.store.S.UpstoxIssued.IsZero() && now.Before(upstoxExpiry(m.store.S.UpstoxIssued))
	m.store.Unlock()

	m.mu.Lock()
	s.LastLoopAt = m.lastLoopAt
	for k, v := range m.providers {
		s.Providers[k] = v
	}
	apnsErr := m.apnsErr
	m.mu.Unlock()
	if _, ok := s.Providers["twelveData"]; !ok && !twelve {
		s.Providers["twelveData"] = "no key (add it in the app)"
	}
	usesUpstox := false
	m.store.Lock()
	for _, t := range m.store.S.Watch {
		if t.Provider == "upstox" {
			usesUpstox = true
		}
	}
	m.store.Unlock()
	if !upstoxValid && usesUpstox {
		s.Providers["upstox"] = "login needed (log in to Upstox in the app)"
	}
	switch {
	case apnsErr != "":
		s.APNs = apnsErr
	case !hasKey:
		s.APNs = "no key — put AuthKey_XXXXXXXXXX.p8 next to thirdeye-monitor.exe"
	case s.Devices == 0:
		s.APNs = "key ready — waiting for the iPhone to connect"
	case !teamKnown:
		s.APNs = "waiting for the app to report its team ID"
	default:
		s.APNs = "ready"
	}
	return s
}
