package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// TokenEntry is one paired device's API token (only its hash is stored).
type TokenEntry struct {
	Hash     string    `json:"hash"`
	Device   string    `json:"device"`
	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"lastUsed"`
}

// State is everything the monitor keeps on disk (state.json in the data folder).
type State struct {
	Version        int                      `json:"version"`
	AdminKey       string                   `json:"adminKey"`
	PairCode       string                   `json:"pairCode,omitempty"`
	PairExpires    time.Time                `json:"pairExpires,omitempty"`
	PairAttempts   int                      `json:"pairAttempts"`
	Tokens         []TokenEntry             `json:"tokens"`
	Devices        []Device                 `json:"devices"`
	Watch          []WatchTrade             `json:"watch"`
	WatchUpdatedAt time.Time                `json:"watchUpdatedAt"`
	Settings       Settings                 `json:"settings"`
	Memory         map[string]*Memory       `json:"memory"`
	Alerts         []Alert                  `json:"alerts"`
	Secrets        map[string]string        `json:"secrets"` // name → base64(DPAPI-encrypted value)
	APNsKeyID      string                   `json:"apnsKeyID,omitempty"`
	UpstoxIssued   time.Time                `json:"upstoxIssued,omitempty"`
	LastSummary    map[string]time.Time     `json:"lastSummary"`
	LastLoginNag   time.Time                `json:"lastLoginNag"`
	LiveActivities map[string]*LiveActivity `json:"liveActivities"` // trade ID → Lock Screen activity
}

const maxAlerts = 200

// Store guards State with a mutex and saves it atomically.
type Store struct {
	mu   sync.Mutex
	path string
	S    State
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	st := &Store{path: filepath.Join(dir, "state.json")}
	if b, err := os.ReadFile(st.path); err == nil {
		if err := json.Unmarshal(b, &st.S); err != nil {
			// Keep the damaged file for inspection and start clean.
			_ = os.Rename(st.path, st.path+".damaged-"+time.Now().Format("20060102-150405"))
			st.S = State{}
		}
	}
	if st.S.Memory == nil {
		st.S.Memory = map[string]*Memory{}
	}
	if st.S.Secrets == nil {
		st.S.Secrets = map[string]string{}
	}
	if st.S.LiveActivities == nil {
		st.S.LiveActivities = map[string]*LiveActivity{}
	}
	if st.S.LastSummary == nil {
		st.S.LastSummary = map[string]time.Time{}
	}
	if st.S.AdminKey == "" {
		st.S.AdminKey = randomHex(24)
	}
	st.S.Version = 1
	return st, st.saveLocked()
}

func (st *Store) Lock()   { st.mu.Lock() }
func (st *Store) Unlock() { st.mu.Unlock() }

// Save writes state.json (call with the lock held).
func (st *Store) saveLocked() error {
	b, err := json.MarshalIndent(st.S, "", " ")
	if err != nil {
		return err
	}
	tmp := st.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

func (st *Store) Save() error { return st.saveLocked() }

// AddAlerts appends to the history, newest first, capped.
func (st *Store) AddAlerts(al []Alert) {
	if len(al) == 0 {
		return
	}
	rev := make([]Alert, 0, len(al))
	for i := len(al) - 1; i >= 0; i-- {
		rev = append(rev, al[i])
	}
	st.S.Alerts = append(rev, st.S.Alerts...)
	if len(st.S.Alerts) > maxAlerts {
		st.S.Alerts = st.S.Alerts[:maxAlerts]
	}
}

// --- secrets ---

func (st *Store) SetSecret(name, value string) error {
	if value == "" {
		delete(st.S.Secrets, name)
		return nil
	}
	enc, err := protect([]byte(value))
	if err != nil {
		return err
	}
	st.S.Secrets[name] = base64.StdEncoding.EncodeToString(enc)
	return nil
}

func (st *Store) Secret(name string) string {
	raw, ok := st.S.Secrets[name]
	if !ok {
		return ""
	}
	enc, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return ""
	}
	plain, err := unprotect(enc)
	if err != nil {
		return ""
	}
	return string(plain)
}

// --- tokens ---

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

// CheckToken reports whether the bearer token belongs to a paired device.
func (st *Store) CheckToken(token string, now time.Time) bool {
	if token == "" {
		return false
	}
	h := hashToken(token)
	for i := range st.S.Tokens {
		if subtle.ConstantTimeCompare([]byte(st.S.Tokens[i].Hash), []byte(h)) == 1 {
			st.S.Tokens[i].LastUsed = now
			return true
		}
	}
	return false
}

func (st *Store) RevokeToken(token string) {
	h := hashToken(token)
	kept := st.S.Tokens[:0]
	for _, t := range st.S.Tokens {
		if t.Hash != h {
			kept = append(kept, t)
		}
	}
	st.S.Tokens = kept
}

var errBadCode = errors.New("wrong or expired pairing code")

// NewPairCode makes a 6-digit code valid for 15 minutes.
func (st *Store) NewPairCode(now time.Time) string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	st.S.PairCode = strconv.Itoa(100000 + int(binary.BigEndian.Uint32(b[:])%900000))
	st.S.PairExpires = now.Add(15 * time.Minute)
	st.S.PairAttempts = 0
	return st.S.PairCode
}

// Pair exchanges a valid code for a new API token.
func (st *Store) Pair(code, device string, now time.Time) (string, error) {
	if st.S.PairCode == "" || now.After(st.S.PairExpires) || st.S.PairAttempts >= 10 {
		return "", errBadCode
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(st.S.PairCode)) != 1 {
		st.S.PairAttempts++
		return "", errBadCode
	}
	token := randomHex(32)
	st.S.Tokens = append(st.S.Tokens, TokenEntry{Hash: hashToken(token), Device: device, Created: now, LastUsed: now})
	st.S.PairCode = ""
	return token, nil
}
