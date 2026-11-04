package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T) (*Monitor, *httptest.Server) {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mon := NewMonitor(store, t.TempDir(), t.TempDir())
	return mon, httptest.NewServer(NewServer(mon).Handler())
}

func do(t *testing.T, method, url, token string, body any, headers map[string]string) (*http.Response, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, url, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func TestPairingAuthAndWatch(t *testing.T) {
	mon, srv := newTestServer(t)
	defer srv.Close()
	admin := map[string]string{"X-Admin-Key": mon.store.S.AdminKey}

	if r, _ := do(t, "GET", srv.URL+"/v1/status", "", nil, nil); r.StatusCode != 401 {
		t.Fatalf("status without token: %d", r.StatusCode)
	}
	if r, _ := do(t, "POST", srv.URL+"/v1/admin/pair-code", "", nil, map[string]string{"X-Admin-Key": "wrong"}); r.StatusCode != 403 {
		t.Fatalf("admin with a bad key: %d", r.StatusCode)
	}
	proxied := map[string]string{"X-Admin-Key": mon.store.S.AdminKey, "X-Forwarded-For": "100.64.0.2"}
	if r, _ := do(t, "POST", srv.URL+"/v1/admin/pair-code", "", nil, proxied); r.StatusCode != 403 {
		t.Fatalf("admin through the Tailscale proxy must be refused: %d", r.StatusCode)
	}
	_, pc := do(t, "POST", srv.URL+"/v1/admin/pair-code", "", nil, admin)
	code, _ := pc["code"].(string)
	if len(code) != 6 {
		t.Fatalf("code %q", code)
	}
	if r, _ := do(t, "POST", srv.URL+"/v1/pair", "", map[string]string{"code": "000000", "device": "x"}, nil); r.StatusCode != 401 {
		t.Fatalf("wrong code: %d", r.StatusCode)
	}
	_, pr := do(t, "POST", srv.URL+"/v1/pair", "", map[string]string{"code": code, "device": "iPhone"}, nil)
	token, _ := pr["token"].(string)
	if len(token) != 64 {
		t.Fatalf("token %v", pr)
	}
	if r, _ := do(t, "POST", srv.URL+"/v1/pair", "", map[string]string{"code": code, "device": "again"}, nil); r.StatusCode != 401 {
		t.Fatal("a code works once")
	}

	trade := longTrade("open")
	trade.AvgEntry = f(100)
	other := longTrade("closed")
	other.ID = "t9"
	r, out := do(t, "PUT", srv.URL+"/v1/watch", token, map[string]any{"trades": []WatchTrade{trade, other},
		"settings": Settings{SuddenMoveR: 1.5}}, nil)
	if r.StatusCode != 200 || out["watching"].(float64) != 1 {
		t.Fatalf("watch: %d %v", r.StatusCode, out)
	}
	r, _ = do(t, "PUT", srv.URL+"/v1/device", token, Device{InstallID: "i1", Token: strings.Repeat("ab", 32), TeamID: "TEAM"}, nil)
	if r.StatusCode != 200 || len(mon.store.S.Devices) != 1 || mon.store.S.Devices[0].Environment != "production" {
		t.Fatalf("device: %d %+v", r.StatusCode, mon.store.S.Devices)
	}
	// Same install, new token → replaced, not added.
	do(t, "PUT", srv.URL+"/v1/device", token, Device{InstallID: "i1", Token: strings.Repeat("cd", 32), TeamID: "TEAM"}, nil)
	if len(mon.store.S.Devices) != 1 || !strings.HasPrefix(mon.store.S.Devices[0].Token, "cdcd") {
		t.Fatalf("device replace: %+v", mon.store.S.Devices)
	}
	key := "td-key"
	do(t, "PUT", srv.URL+"/v1/credentials", token, map[string]any{"twelveDataKey": key}, nil)
	if mon.store.Secret("twelveDataKey") != key {
		t.Fatal("credential stored")
	}
	_, st := do(t, "GET", srv.URL+"/v1/status", token, nil, nil)
	if st["watching"].(float64) != 1 || !strings.Contains(st["apns"].(string), "no key") {
		t.Fatalf("status %v", st)
	}
	do(t, "DELETE", srv.URL+"/v1/pair", token, nil, nil)
	if r, _ := do(t, "GET", srv.URL+"/v1/status", token, nil, nil); r.StatusCode != 401 {
		t.Fatal("unpaired token must stop working")
	}
}

func TestPairingBruteForceLimit(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	code := store.NewPairCode(t0)
	for i := 0; i < 10; i++ {
		_, _ = store.Pair("999999", "x", t0)
	}
	if _, err := store.Pair(code, "x", t0); err == nil {
		t.Fatal("after 10 wrong tries the code must be dead")
	}
	code = store.NewPairCode(t0)
	if _, err := store.Pair(code, "x", t0.Add(16*time.Minute)); err == nil {
		t.Fatal("codes expire after 15 minutes")
	}
}

func TestTickFetchesEvaluatesAndDelivers(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	mon := NewMonitor(store, t.TempDir(), t.TempDir())
	tr := longTrade("open")
	tr.AvgEntry = f(100)
	store.S.Watch = []WatchTrade{tr}
	store.S.Devices = []Device{{InstallID: "i", Token: strings.Repeat("ab", 32), TeamID: "T"}}
	var fetched []string
	mon.fetch = func(ctx context.Context, provider string, keys []string, secret string) (map[string]float64, error) {
		fetched = append(fetched, provider+":"+strings.Join(keys, ","))
		return map[string]float64{"BTCUSDT": 94}, nil // below the stop
	}
	var sent []Alert
	mon.send = func(ctx context.Context, d Device, al Alert, now time.Time) error {
		sent = append(sent, al)
		return nil
	}
	now := time.Date(2026, 11, 5, 6, 0, 0, 0, time.UTC) // 11:30 IST: outside the 09:00/21:00 digest windows
	mon.Tick(context.Background(), now)
	if strings.Join(fetched, ";") != "binance:BTCUSDT" {
		t.Fatalf("fetched %v", fetched)
	}
	if len(sent) != 1 || sent[0].Kind != "stop" {
		t.Fatalf("sent %+v", sent)
	}
	if store.S.Alerts[0].Delivered != "sent to 1 device(s)" {
		t.Fatalf("history %+v", store.S.Alerts)
	}
	// Not due again before its cadence (5 min).
	mon.Tick(context.Background(), now.Add(30*time.Second))
	if len(fetched) != 1 {
		t.Fatalf("cadence ignored: %v", fetched)
	}
}

func TestMorningSummaryOnce(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	mon := NewMonitor(store, t.TempDir(), t.TempDir())
	store.S.Watch = []WatchTrade{longTrade("upcoming")}
	mon.fetch = func(ctx context.Context, provider string, keys []string, secret string) (map[string]float64, error) {
		return map[string]float64{"BTCUSDT": 110}, nil
	}
	var kinds []string
	mon.send = func(ctx context.Context, d Device, al Alert, now time.Time) error {
		kinds = append(kinds, al.Kind)
		return nil
	}
	store.S.Devices = []Device{{Token: strings.Repeat("ab", 32), TeamID: "T"}}
	nine := time.Date(2026, 11, 5, 9, 5, 0, 0, istZone)
	mon.Tick(context.Background(), nine)
	mon.Tick(context.Background(), nine.Add(10*time.Minute))
	if strings.Join(kinds, ",") != "summary" {
		t.Fatalf("one summary expected, got %v", kinds)
	}
}

func TestDeviceGoneIsRemoved(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	mon := NewMonitor(store, t.TempDir(), t.TempDir())
	store.S.Devices = []Device{{Token: "old"}, {Token: "good"}}
	mon.send = func(ctx context.Context, d Device, al Alert, now time.Time) error {
		if d.Token == "old" {
			return ErrDeviceGone
		}
		return nil
	}
	al := []Alert{{Title: "x"}}
	mon.deliver(context.Background(), store.S.Devices, al, t0)
	if len(store.S.Devices) != 1 || store.S.Devices[0].Token != "good" || al[0].Delivered != "sent to 1 device(s)" {
		t.Fatalf("%+v %+v", store.S.Devices, al)
	}
}

func TestAPNsKeyImport(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	exeDir := t.TempDir()
	mon := NewMonitor(store, t.TempDir(), exeDir)
	p8, _ := testKeyPEM(t)
	path := exeDir + "/AuthKey_ABCDE12345.p8"
	if err := writeFile(path, p8); err != nil {
		t.Fatal(err)
	}
	mon.importAPNsKey()
	if store.S.APNsKeyID != "ABCDE12345" || store.Secret("apnsKey") == "" {
		t.Fatalf("not imported: %q", store.S.APNsKeyID)
	}
	if fileExists(path) || !fileExists(path+".imported") {
		t.Fatal("the key file should be renamed after import")
	}
}
