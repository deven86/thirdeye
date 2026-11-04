package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ErrLoginNeeded means the Upstox daily token is missing or expired (it ends at 03:30 IST).
var ErrLoginNeeded = errors.New("Upstox login needed")

// ErrNoKey means the Twelve Data key has not been sent from the app yet.
var ErrNoKey = errors.New("Twelve Data key not set")

var httpClient = &http.Client{Timeout: 20 * time.Second}

func getJSON(ctx context.Context, rawURL string, headers map[string]string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ThirdEyeMonitor/"+version)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return body, resp.StatusCode, err
}

// --- Binance (public market data, no key) ---

const binanceBase = "https://data-api.binance.vision/api/v3"

// BinancePrices fetches last prices for symbols like "BTCUSDT".
func BinancePrices(ctx context.Context, symbols []string) (map[string]float64, error) {
	if len(symbols) == 0 {
		return map[string]float64{}, nil
	}
	quoted := make([]string, len(symbols))
	for i, s := range symbols {
		quoted[i] = strconv.Quote(s)
	}
	u := binanceBase + "/ticker/price?symbols=" + url.QueryEscape("["+strings.Join(quoted, ",")+"]")
	body, status, err := getJSON(ctx, u, nil)
	if err != nil {
		return nil, err
	}
	if status == 400 && len(symbols) > 1 {
		// One bad symbol fails the whole batch: fall back to one request each.
		out := map[string]float64{}
		for _, s := range symbols {
			if m, err := BinancePrices(ctx, []string{s}); err == nil {
				for k, v := range m {
					out[k] = v
				}
			}
		}
		return out, nil
	}
	if status != 200 {
		return nil, fmt.Errorf("Binance HTTP %d: %s", status, snippet(body))
	}
	return parseBinancePrices(body)
}

func parseBinancePrices(body []byte) (map[string]float64, error) {
	var rows []struct {
		Symbol string `json:"symbol"`
		Price  string `json:"price"`
	}
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, fmt.Errorf("Binance prices: %w", err)
	}
	out := map[string]float64{}
	for _, r := range rows {
		if v, err := strconv.ParseFloat(r.Price, 64); err == nil && v > 0 {
			out[r.Symbol] = v
		}
	}
	return out, nil
}

// --- Twelve Data (US stocks, forex, metals; free plan: 8 symbols a minute) ---

const twelveBase = "https://api.twelvedata.com"

func TwelveDataPrices(ctx context.Context, key string, symbols []string) (map[string]float64, error) {
	if key == "" {
		return nil, ErrNoKey
	}
	if len(symbols) == 0 {
		return map[string]float64{}, nil
	}
	u := twelveBase + "/price?symbol=" + url.QueryEscape(strings.Join(symbols, ","))
	body, status, err := getJSON(ctx, u, map[string]string{"Authorization": "apikey " + key})
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("Twelve Data HTTP %d: %s", status, snippet(body))
	}
	return parseTwelvePrices(body, symbols)
}

func parseTwelvePrices(body []byte, symbols []string) (map[string]float64, error) {
	var generic map[string]json.RawMessage
	if err := json.Unmarshal(body, &generic); err != nil {
		return nil, fmt.Errorf("Twelve Data prices: %w", err)
	}
	type quote struct {
		Price   string `json:"price"`
		Status  string `json:"status"`
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	out := map[string]float64{}
	if _, single := generic["price"]; single || generic["status"] != nil {
		var q quote
		_ = json.Unmarshal(body, &q)
		if q.Status == "error" {
			return nil, fmt.Errorf("Twelve Data %d: %s", q.Code, q.Message)
		}
		if v, err := strconv.ParseFloat(q.Price, 64); err == nil && len(symbols) == 1 {
			out[symbols[0]] = v
		}
		return out, nil
	}
	for sym, raw := range generic {
		var q quote
		if json.Unmarshal(raw, &q) == nil && q.Status != "error" {
			if v, err := strconv.ParseFloat(q.Price, 64); err == nil && v > 0 {
				out[sym] = v
			}
		}
	}
	return out, nil
}

// --- Upstox (India; needs the daily access token from the app) ---

const upstoxBase = "https://api.upstox.com"

func UpstoxPrices(ctx context.Context, token string, keys []string) (map[string]float64, error) {
	if token == "" {
		return nil, ErrLoginNeeded
	}
	if len(keys) == 0 {
		return map[string]float64{}, nil
	}
	headers := map[string]string{"Authorization": "Bearer " + token}
	q := url.QueryEscape(strings.Join(keys, ","))
	var lastErr error
	for _, path := range []string{"/v3/market-quote/ltp", "/v2/market-quote/ltp"} {
		body, status, err := getJSON(ctx, upstoxBase+path+"?instrument_key="+q, headers)
		if err != nil {
			lastErr = err
			continue
		}
		if status == 401 {
			return nil, ErrLoginNeeded
		}
		if status != 200 {
			lastErr = fmt.Errorf("Upstox HTTP %d: %s", status, snippet(body))
			continue
		}
		return parseUpstoxLTP(body, keys)
	}
	return nil, lastErr
}

// parseUpstoxLTP: {"status":"success","data":{"NSE_EQ:RELIANCE":{"last_price":2731.5,"instrument_token":"NSE_EQ|INE002A01018"}}}
func parseUpstoxLTP(body []byte, keys []string) (map[string]float64, error) {
	var root struct {
		Status string `json:"status"`
		Data   map[string]struct {
			LastPrice       float64 `json:"last_price"`
			InstrumentToken string  `json:"instrument_token"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &root); err != nil {
		return nil, fmt.Errorf("Upstox LTP: %w", err)
	}
	out := map[string]float64{}
	for k, v := range root.Data {
		if v.LastPrice <= 0 {
			continue
		}
		switch {
		case v.InstrumentToken != "":
			out[v.InstrumentToken] = v.LastPrice
		case len(keys) == 1:
			out[keys[0]] = v.LastPrice
		default:
			out[strings.Replace(k, ":", "|", 1)] = v.LastPrice
		}
	}
	return out, nil
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
