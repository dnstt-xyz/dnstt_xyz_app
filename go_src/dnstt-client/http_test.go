package main

import (
	"testing"
	"time"
)

// mustParseTime parses a time string using the time.RFC3339 format, or panics.
func mustParseTime(value string) time.Time {
	t, err := time.Parse(time.RFC3339, value)
	if err != nil {
		panic(err)
	}
	return t
}

func TestParseRetryAfter(t *testing.T) {
	now := mustParseTime("2000-01-01T06:00:00Z")
	for _, test := range []struct {
		value    string
		expected string
	}{
		{"", "error"},
		{"0", now.Format(time.RFC3339)},
		{"100", "2000-01-01T06:01:40Z"},
		{"0100", "2000-01-01T06:01:40Z"},
		{"-100", "error"},
		{"9999999999999", "error"},
		{"Fri, 31 Dec 1999 23:59:59 GMT", "1999-12-31T23:59:59Z"},
		{"xxx", "error"},
	} {
		result, err := parseRetryAfter(test.value, now)
		if test.expected == "error" {
			if err == nil {
				t.Errorf("%+q returned (%v, %v), expected error",
					test.value, result.Format(time.RFC3339), err)
			}
		} else {
			expectedResult := mustParseTime(test.expected)
			if err != nil || result != expectedResult {
				t.Errorf("%+q returned (%v, %v), expected (%v, %v)",
					test.value, result.Format(time.RFC3339),
					err, expectedResult.Format(time.RFC3339), nil)
			}
		}
	}
}
