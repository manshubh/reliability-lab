// Package config reads service settings from environment variables.
//
// Every service is configured through its environment only, so one image runs
// unchanged on a laptop and in CI, and a setting is visible in the pod spec.
//
// A Loader keeps going after the first problem and reports them all from Err,
// so a misconfigured pod lists every bad setting in one crash instead of one
// per restart.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Loader reads typed values from an environment and remembers what went wrong.
type Loader struct {
	lookup  func(name string) (string, bool)
	missing []string
	invalid []error
}

// New returns a Loader that reads the process environment.
func New() *Loader {
	return FromLookup(os.LookupEnv)
}

// FromLookup returns a Loader that reads from lookup instead of the process
// environment. Tests use it to avoid touching global state.
func FromLookup(lookup func(name string) (string, bool)) *Loader {
	return &Loader{lookup: lookup}
}

// raw returns the value of name, treating "set but empty" as unset. That way
// a manifest line like `FOO: ""` falls back to the default instead of
// producing a confusing parse error.
func (l *Loader) raw(name string) (string, bool) {
	v, ok := l.lookup(name)
	v = strings.TrimSpace(v)
	if !ok || v == "" {
		return "", false
	}
	return v, true
}

// String returns the value of name, or def when it is unset.
func (l *Loader) String(name, def string) string {
	if v, ok := l.raw(name); ok {
		return v
	}
	return def
}

// RequiredString returns the value of name. When it is unset, the name is
// recorded and reported by Err.
func (l *Loader) RequiredString(name string) string {
	v, ok := l.raw(name)
	if !ok {
		l.missing = append(l.missing, name)
	}
	return v
}

// Int returns the value of name as an int, or def when it is unset.
func (l *Loader) Int(name string, def int) int {
	v, ok := l.raw(name)
	if !ok {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		l.invalid = append(l.invalid, fmt.Errorf("%s: %q is not an integer", name, v))
		return def
	}
	return n
}

// Duration returns the value of name parsed by time.ParseDuration (for
// example "250ms" or "5s"), or def when it is unset.
func (l *Loader) Duration(name string, def time.Duration) time.Duration {
	v, ok := l.raw(name)
	if !ok {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		l.invalid = append(l.invalid, fmt.Errorf("%s: %q is not a duration (try 250ms or 5s)", name, v))
		return def
	}
	return d
}

// Bool returns the value of name as a bool, or def when it is unset.
// It accepts "on" and "off" as well as what strconv.ParseBool accepts,
// because feature switches read more naturally as RETRY_JITTER=off.
func (l *Loader) Bool(name string, def bool) bool {
	v, ok := l.raw(name)
	if !ok {
		return def
	}
	switch strings.ToLower(v) {
	case "on":
		return true
	case "off":
		return false
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		l.invalid = append(l.invalid, fmt.Errorf("%s: %q is not a boolean (use on/off or true/false)", name, v))
		return def
	}
	return b
}

// Err reports every missing required value and every value that failed to
// parse, or nil when there were none.
func (l *Loader) Err() error {
	var errs []error
	if len(l.missing) > 0 {
		errs = append(errs, fmt.Errorf("missing required environment variables: %s", strings.Join(l.missing, ", ")))
	}
	errs = append(errs, l.invalid...)
	return errors.Join(errs...)
}
