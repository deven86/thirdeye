package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"
)

// Server is the small HTTPS API (reached through `tailscale serve`) that the app talks to.
type Server struct {
	mon *Monitor
	now func() time.Time
}

func NewServer(mon *Monitor) *Server { return &Server{mon: mon, now: time.Now} }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) })
	mux.HandleFunc("POST /v1/pair", s.pair)
	mux.HandleFunc("DELETE /v1/pair", s.auth(s.unpair))
	mux.HandleFunc("GET /v1/status", s.auth(s.status))
	mux.HandleFunc("PUT /v1/device", s.auth(s.device))
	mux.HandleFunc("PUT /v1/watch", s.auth(s.watch))
	mux.HandleFunc("PUT /v1/credentials", s.auth(s.credentials))
	mux.HandleFunc("POST /v1/test-alert", s.auth(s.testAlert))
	mux.HandleFunc("POST /v1/admin/pair-code", s.admin(s.pairCode))
	mux.HandleFunc("GET /v1/admin/status", s.admin(s.status))
	return limitBody(mux)
}

func limitBody(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
		h.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

// auth requires a token from pairing.
func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		st := s.mon.store
		st.Lock()
		ok := st.CheckToken(bearer(r), s.now())
		st.Unlock()
		if !ok {
			fail(w, http.StatusUnauthorized, "not paired — pair again in Third Eye")
			return
		}
		next(w, r)
	}
}

// admin is for the command line on the PC itself: it needs the local admin key and must not come
// through the Tailscale proxy (which adds forwarding headers).
func (s *Server) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("Tailscale-User-Login") != "" {
			fail(w, http.StatusForbidden, "admin is local only")
			return
		}
		st := s.mon.store
		st.Lock()
		key := st.S.AdminKey
		st.Unlock()
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-Admin-Key")), []byte(key)) != 1 {
			fail(w, http.StatusForbidden, "bad admin key")
			return
		}
		next(w, r)
	}
}

func decode(r *http.Request, v any) error {
	d := json.NewDecoder(r.Body)
	return d.Decode(v)
}

func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code   string `json:"code"`
		Device string `json:"device"`
	}
	if err := decode(r, &in); err != nil {
		fail(w, http.StatusBadRequest, "bad request")
		return
	}
	st := s.mon.store
	st.Lock()
	token, err := st.Pair(strings.TrimSpace(in.Code), in.Device, s.now())
	_ = st.Save()
	st.Unlock()
	if err != nil {
		fail(w, http.StatusUnauthorized, err.Error())
		return
	}
	log.Printf("paired %q", in.Device)
	writeJSON(w, http.StatusOK, map[string]string{"token": token, "version": version})
}

func (s *Server) unpair(w http.ResponseWriter, r *http.Request) {
	st := s.mon.store
	st.Lock()
	st.RevokeToken(bearer(r))
	_ = st.Save()
	st.Unlock()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.mon.Status(s.now()))
}

func (s *Server) device(w http.ResponseWriter, r *http.Request) {
	var d Device
	if err := decode(r, &d); err != nil || len(d.Token) < 32 {
		fail(w, http.StatusBadRequest, "bad device")
		return
	}
	if d.Environment != "development" {
		d.Environment = "production"
	}
	d.UpdatedAt = s.now()
	st := s.mon.store
	st.Lock()
	replaced := false
	for i := range st.S.Devices {
		if st.S.Devices[i].Token == d.Token || (d.InstallID != "" && st.S.Devices[i].InstallID == d.InstallID) {
			st.S.Devices[i] = d
			replaced = true
			break
		}
	}
	if !replaced {
		st.S.Devices = append(st.S.Devices, d)
	}
	_ = st.Save()
	st.Unlock()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) watch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Trades   []WatchTrade `json:"trades"`
		Settings *Settings    `json:"settings"`
	}
	if err := decode(r, &in); err != nil {
		fail(w, http.StatusBadRequest, "bad request: "+err.Error())
		return
	}
	var valid []WatchTrade
	for _, t := range in.Trades {
		if t.ID == "" || t.ProviderKey == "" || (t.Status != "upcoming" && t.Status != "open") {
			continue
		}
		valid = append(valid, t)
	}
	st := s.mon.store
	st.Lock()
	st.S.Watch = valid
	st.S.WatchUpdatedAt = s.now()
	if in.Settings != nil {
		st.S.Settings = *in.Settings
	}
	keep := map[string]bool{}
	for _, t := range valid {
		keep[t.ID] = true
	}
	for id := range st.S.Memory {
		if !keep[id] {
			delete(st.S.Memory, id)
		}
	}
	_ = st.Save()
	st.Unlock()
	writeJSON(w, http.StatusOK, map[string]int{"watching": len(valid)})
}

func (s *Server) credentials(w http.ResponseWriter, r *http.Request) {
	var in struct {
		TwelveDataKey  *string    `json:"twelveDataKey"`
		UpstoxToken    *string    `json:"upstoxToken"`
		UpstoxIssuedAt *time.Time `json:"upstoxIssuedAt"`
	}
	if err := decode(r, &in); err != nil {
		fail(w, http.StatusBadRequest, "bad request")
		return
	}
	st := s.mon.store
	st.Lock()
	var err error
	if in.TwelveDataKey != nil {
		err = errors.Join(err, st.SetSecret("twelveDataKey", *in.TwelveDataKey))
	}
	if in.UpstoxToken != nil {
		err = errors.Join(err, st.SetSecret("upstoxToken", *in.UpstoxToken))
		st.S.UpstoxIssued = time.Time{}
		if in.UpstoxIssuedAt != nil {
			st.S.UpstoxIssued = *in.UpstoxIssuedAt
		}
	}
	_ = st.Save()
	st.Unlock()
	if err != nil {
		fail(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) testAlert(w http.ResponseWriter, r *http.Request) {
	now := s.now()
	al := Alert{ID: newID(), Kind: "test", Title: "Third Eye · test alert", Urgent: true, At: now,
		Body: "Your PC monitor can reach this device. Stop-loss alerts arrive like this, even in Focus."}
	st := s.mon.store
	st.Lock()
	devices := append([]Device(nil), st.S.Devices...)
	st.Unlock()
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	alerts := []Alert{al}
	s.mon.deliver(ctx, devices, alerts, now)
	st.Lock()
	st.AddAlerts(alerts)
	_ = st.Save()
	st.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"delivered": alerts[0].Delivered})
}

func (s *Server) pairCode(w http.ResponseWriter, r *http.Request) {
	st := s.mon.store
	st.Lock()
	code := st.NewPairCode(s.now())
	exp := st.S.PairExpires
	_ = st.Save()
	st.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"code": code, "expires": exp})
}
