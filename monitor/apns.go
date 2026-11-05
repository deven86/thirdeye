package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// APNs sends Apple push notifications with a token-based (.p8) key.
type APNs struct {
	KeyID  string
	TeamID string
	Key    *ecdsa.PrivateKey
	Client *http.Client

	mu    sync.Mutex
	jwt   string
	jwtAt time.Time
}

// ErrDeviceGone means Apple says the device token is no longer valid (app deleted or token rotated).
var ErrDeviceGone = errors.New("device token no longer valid")

// ParseP8 reads an AuthKey_XXXXXXXXXX.p8 file (PKCS#8 EC private key).
func ParseP8(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("not a PEM file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an EC private key")
	}
	return ec, nil
}

// Token returns the provider JWT (ES256), reused for 50 minutes as Apple asks (refresh no more than every 20).
func (a *APNs) Token(now time.Time) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt != "" && now.Sub(a.jwtAt) < 50*time.Minute {
		return a.jwt, nil
	}
	if a.Key == nil || a.KeyID == "" || a.TeamID == "" {
		return "", errors.New("APNs key, key ID or team ID missing")
	}
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": a.TeamID, "iat": now.Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.Key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64) // JWS wants raw r||s, each 32 bytes
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt = signing + "." + enc.EncodeToString(sig)
	a.jwtAt = now
	return a.jwt, nil
}

// Payload builds the notification JSON.
func Payload(al Alert) []byte {
	level := "active"
	if al.Urgent {
		level = "time-sensitive"
	}
	aps := map[string]any{
		"alert":              map[string]string{"title": al.Title, "body": al.Body},
		"sound":              "default",
		"interruption-level": level,
	}
	if al.TradeID != "" {
		aps["thread-id"] = al.TradeID
	}
	body, _ := json.Marshal(map[string]any{"aps": aps, "tradeID": al.TradeID, "kind": al.Kind, "alertID": al.ID})
	return body
}

// Send delivers one alert to one device.
func (a *APNs) Send(ctx context.Context, d Device, al Alert, now time.Time) error {
	topic := d.BundleID
	if topic == "" {
		topic = "com.jondhale.thirdeye"
	}
	return a.post(ctx, d.Environment, d.Token, topic, "alert", 10, now.Add(time.Hour), Payload(al), now)
}

// SendLive updates (or ends) one Live Activity. The topic is the app's bundle ID + ".push-type.liveactivity".
func (a *APNs) SendLive(ctx context.Context, la LiveActivity, body []byte, priority int, now time.Time) error {
	bundle := la.BundleID
	if bundle == "" {
		bundle = "com.jondhale.thirdeye"
	}
	return a.post(ctx, la.Environment, la.Token, bundle+".push-type.liveactivity", "liveactivity", priority,
		now.Add(15*time.Minute), body, now)
}

func (a *APNs) post(ctx context.Context, environment, token, topic, pushType string, priority int, expires time.Time,
	body []byte, now time.Time) error {
	jwt, err := a.Token(now)
	if err != nil {
		return err
	}
	host := "https://api.push.apple.com"
	if environment == "development" {
		host = "https://api.sandbox.push.apple.com"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", fmt.Sprint(priority))
	req.Header.Set("apns-expiration", fmt.Sprint(expires.Unix()))
	client := a.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second} // net/http negotiates HTTP/2 with Apple
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return nil
	}
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var reason struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(b, &reason)
	if resp.StatusCode == 410 || reason.Reason == "BadDeviceToken" || reason.Reason == "Unregistered" || reason.Reason == "ExpiredToken" {
		return fmt.Errorf("%w (%s)", ErrDeviceGone, reason.Reason)
	}
	if reason.Reason == "ExpiredProviderToken" || reason.Reason == "InvalidProviderToken" {
		a.mu.Lock()
		a.jwt = "" // force a fresh JWT next time
		a.mu.Unlock()
	}
	return fmt.Errorf("APNs %d %s", resp.StatusCode, reason.Reason)
}
