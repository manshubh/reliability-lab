package config

import (
	"strings"
	"testing"
	"time"
)

// env builds a lookup function from a map, standing in for the process environment.
func env(vars map[string]string) func(string) (string, bool) {
	return func(name string) (string, bool) {
		v, ok := vars[name]
		return v, ok
	}
}

func TestString(t *testing.T) {
	tests := []struct {
		name string
		vars map[string]string
		want string
	}{
		{"set", map[string]string{"ADDR": ":9090"}, ":9090"},
		{"unset uses default", nil, ":8080"},
		{"empty uses default", map[string]string{"ADDR": ""}, ":8080"},
		{"spaces are trimmed", map[string]string{"ADDR": "  :9090 "}, ":9090"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := FromLookup(env(tt.vars))
			if got := l.String("ADDR", ":8080"); got != tt.want {
				t.Errorf("String() = %q, want %q", got, tt.want)
			}
			if err := l.Err(); err != nil {
				t.Errorf("Err() = %v, want nil", err)
			}
		})
	}
}

func TestInt(t *testing.T) {
	tests := []struct {
		name    string
		vars    map[string]string
		want    int
		wantErr string
	}{
		{"set", map[string]string{"POOL_SIZE": "12"}, 12, ""},
		{"unset uses default", nil, 4, ""},
		{"invalid keeps default and reports", map[string]string{"POOL_SIZE": "lots"}, 4, `POOL_SIZE: "lots" is not an integer`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := FromLookup(env(tt.vars))
			if got := l.Int("POOL_SIZE", 4); got != tt.want {
				t.Errorf("Int() = %d, want %d", got, tt.want)
			}
			checkErr(t, l.Err(), tt.wantErr)
		})
	}
}

func TestDuration(t *testing.T) {
	tests := []struct {
		name    string
		vars    map[string]string
		want    time.Duration
		wantErr string
	}{
		{"milliseconds", map[string]string{"TIMEOUT": "250ms"}, 250 * time.Millisecond, ""},
		{"seconds", map[string]string{"TIMEOUT": "5s"}, 5 * time.Second, ""},
		{"unset uses default", nil, time.Second, ""},
		{"bare number is rejected", map[string]string{"TIMEOUT": "5"}, time.Second, `TIMEOUT: "5" is not a duration`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := FromLookup(env(tt.vars))
			if got := l.Duration("TIMEOUT", time.Second); got != tt.want {
				t.Errorf("Duration() = %v, want %v", got, tt.want)
			}
			checkErr(t, l.Err(), tt.wantErr)
		})
	}
}

func TestBool(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		set     bool
		want    bool
		wantErr string
	}{
		{"on", "on", true, true, ""},
		{"off", "off", true, false, ""},
		{"upper case OFF", "OFF", true, false, ""},
		{"true", "true", true, true, ""},
		{"zero", "0", true, false, ""},
		{"unset uses default", "", false, true, ""},
		{"invalid keeps default and reports", "maybe", true, true, `FEATURE: "maybe" is not a boolean`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			vars := map[string]string{}
			if tt.set {
				vars["FEATURE"] = tt.value
			}
			l := FromLookup(env(vars))
			if got := l.Bool("FEATURE", true); got != tt.want {
				t.Errorf("Bool() = %v, want %v", got, tt.want)
			}
			checkErr(t, l.Err(), tt.wantErr)
		})
	}
}

// A pod with several bad settings should report all of them at once.
func TestErrCollectsEveryProblem(t *testing.T) {
	l := FromLookup(env(map[string]string{
		"POOL_SIZE": "lots",
		"TIMEOUT":   "soon",
	}))
	l.RequiredString("DATABASE_URL")
	l.RequiredString("PAYMENTS_URL")
	l.Int("POOL_SIZE", 4)
	l.Duration("TIMEOUT", time.Second)

	err := l.Err()
	if err == nil {
		t.Fatal("Err() = nil, want an error")
	}
	for _, want := range []string{
		"missing required environment variables: DATABASE_URL, PAYMENTS_URL",
		`POOL_SIZE: "lots" is not an integer`,
		`TIMEOUT: "soon" is not a duration`,
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Err() = %q, want it to contain %q", err, want)
		}
	}
}

func TestRequiredStringSet(t *testing.T) {
	l := FromLookup(env(map[string]string{"DATABASE_URL": "postgres://db"}))
	if got := l.RequiredString("DATABASE_URL"); got != "postgres://db" {
		t.Errorf("RequiredString() = %q, want %q", got, "postgres://db")
	}
	if err := l.Err(); err != nil {
		t.Errorf("Err() = %v, want nil", err)
	}
}

func checkErr(t *testing.T, err error, want string) {
	t.Helper()
	switch {
	case want == "" && err != nil:
		t.Errorf("Err() = %v, want nil", err)
	case want != "" && err == nil:
		t.Errorf("Err() = nil, want an error containing %q", want)
	case want != "" && !strings.Contains(err.Error(), want):
		t.Errorf("Err() = %q, want it to contain %q", err, want)
	}
}
