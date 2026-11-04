package main

import (
	"crypto/rand"
	"encoding/hex"
	"math"
	"strconv"
	"strings"
)

// decimals mirrors the app: small prices need more places.
func decimals(p float64) int {
	a := math.Abs(p)
	switch {
	case a < 1:
		return 5
	case a < 10:
		return 4
	default:
		return 2
	}
}

// money formats a price with grouping: Indian style (1,23,456.78) for INR, otherwise 123,456.78.
func money(p float64, currency string) string {
	s := strconv.FormatFloat(math.Abs(p), 'f', decimals(p), 64)
	intPart, frac := s, ""
	if i := strings.IndexByte(s, '.'); i >= 0 {
		intPart, frac = s[:i], s[i:]
	}
	var grouped string
	if currency == "INR" && len(intPart) > 3 {
		head, tail := intPart[:len(intPart)-3], intPart[len(intPart)-3:]
		var parts []string
		for len(head) > 2 {
			parts = append([]string{head[len(head)-2:]}, parts...)
			head = head[:len(head)-2]
		}
		if head != "" {
			parts = append([]string{head}, parts...)
		}
		grouped = strings.Join(parts, ",") + "," + tail
	} else {
		var b strings.Builder
		for i, c := range intPart {
			if i > 0 && (len(intPart)-i)%3 == 0 {
				b.WriteByte(',')
			}
			b.WriteRune(c)
		}
		grouped = b.String()
	}
	if p < 0 {
		grouped = "-" + grouped
	}
	return grouped + frac
}

func ftoa(f float64) string { return strconv.FormatFloat(f, 'g', -1, 64) }

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
