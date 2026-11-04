package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testKeyPEM(t *testing.T) ([]byte, *ecdsa.PrivateKey) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(k)
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), k
}

func TestJWTIsValidES256(t *testing.T) {
	p8, key := testKeyPEM(t)
	parsed, err := ParseP8(p8)
	if err != nil {
		t.Fatal(err)
	}
	a := &APNs{KeyID: "ABC123DEFG", TeamID: "TEAM123456", Key: parsed}
	tok, err := a.Token(t0)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt parts %d", len(parts))
	}
	hdr, _ := base64.RawURLEncoding.DecodeString(parts[0])
	claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if string(hdr) != `{"alg":"ES256","kid":"ABC123DEFG"}` {
		t.Fatalf("header %s", hdr)
	}
	var c map[string]any
	_ = json.Unmarshal(claims, &c)
	if c["iss"] != "TEAM123456" || int64(c["iat"].(float64)) != t0.Unix() {
		t.Fatalf("claims %s", claims)
	}
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("raw signature must be 64 bytes, got %d", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("signature does not verify")
	}
	again, _ := a.Token(t0.Add(30 * time.Minute))
	if again != tok {
		t.Fatal("token should be reused within 50 minutes")
	}
	fresh, _ := a.Token(t0.Add(51 * time.Minute))
	if fresh == tok {
		t.Fatal("token should refresh after 50 minutes")
	}
}

func TestPayload(t *testing.T) {
	var p map[string]any
	_ = json.Unmarshal(Payload(Alert{ID: "a1", TradeID: "t1", Kind: "stop", Title: "T", Body: "B", Urgent: true}), &p)
	aps := p["aps"].(map[string]any)
	if aps["interruption-level"] != "time-sensitive" || aps["sound"] != "default" || aps["thread-id"] != "t1" || p["tradeID"] != "t1" {
		t.Fatalf("payload %v", p)
	}
}

func TestSendHandlesAppleResponses(t *testing.T) {
	p8, _ := testKeyPEM(t)
	key, _ := ParseP8(p8)
	var gotPath, gotTopic, gotAuth string
	status, body := 200, ""
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotTopic, gotAuth = r.URL.Path, r.Header.Get("apns-topic"), r.Header.Get("authorization")
		_, _ = io.ReadAll(r.Body)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	client := srv.Client()
	client.Transport.(*http.Transport).DialContext = nil
	a := &APNs{KeyID: "K", TeamID: "T", Key: key, Client: client}
	// Point the production host at the test server.
	client.Transport = rewriteHost{srv.URL, client.Transport}
	d := Device{Token: strings.Repeat("ab", 32), BundleID: "com.jondhale.thirdeye"}
	if err := a.Send(context.Background(), d, Alert{Title: "x"}, t0); err != nil {
		t.Fatal(err)
	}
	if gotPath != "/3/device/"+d.Token || gotTopic != "com.jondhale.thirdeye" || !strings.HasPrefix(gotAuth, "bearer ") {
		t.Fatalf("request %s %s %s", gotPath, gotTopic, gotAuth)
	}
	status, body = 410, `{"reason":"Unregistered"}`
	if err := a.Send(context.Background(), d, Alert{Title: "x"}, t0); err == nil || !strings.Contains(err.Error(), "no longer valid") {
		t.Fatalf("410 should mean device gone: %v", err)
	}
}

type rewriteHost struct {
	base string
	next http.RoundTripper
}

func (r rewriteHost) RoundTrip(req *http.Request) (*http.Response, error) {
	u := *req.URL
	host := strings.TrimPrefix(r.base, "https://")
	u.Host = host
	clone := req.Clone(req.Context())
	clone.URL = &u
	clone.Host = host
	return r.next.RoundTrip(clone)
}
