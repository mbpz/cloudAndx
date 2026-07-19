package main

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddress         string
	DataDir               string
	AndroidVersion        string
	APILevel              int
	SystemImageKind       string
	KVMAvailable          bool
	RuntimeMode           string
	MaxActiveSessions     int
	PreflightEvidenceFile string
	ProbeFileTemplate     string
	ProbeURLTemplate      string
	ProbeMaxAge           time.Duration
	ProbeTimeout          time.Duration
	HTTPWriteTimeout      time.Duration
	DefaultLease          time.Duration
	MaximumLease          time.Duration
	MinimumLease          time.Duration
}

const minimumHTTPWriteTimeoutHeadroom = 5 * time.Second

func ConfigFromEnv() (Config, error) {
	apiLevel, err := envInt("API_LEVEL", 37)
	if err != nil || apiLevel <= 0 {
		return Config{}, fmt.Errorf("API_LEVEL must be a positive integer")
	}

	kvm, err := envBool("KVM_AVAILABLE", false)
	if err != nil {
		return Config{}, err
	}

	probeMaxAgeSeconds, err := envInt("PROBE_MAX_AGE_SECONDS", 30)
	if err != nil || probeMaxAgeSeconds <= 0 {
		return Config{}, fmt.Errorf("PROBE_MAX_AGE_SECONDS must be a positive integer")
	}
	probeTimeout, err := envMilliseconds("PROBE_TIMEOUT_MILLIS", 2*time.Second)
	if err != nil {
		return Config{}, err
	}
	if probeTimeout > time.Duration(1<<63-1)-minimumHTTPWriteTimeoutHeadroom {
		return Config{}, fmt.Errorf("PROBE_TIMEOUT_MILLIS leaves no room for the HTTP write timeout")
	}
	httpWriteTimeout, err := envMilliseconds("HTTP_WRITE_TIMEOUT_MILLIS", probeTimeout+minimumHTTPWriteTimeoutHeadroom)
	if err != nil {
		return Config{}, err
	}
	maxActiveSessions, err := envInt("MAX_ACTIVE_SESSIONS", 1)
	if err != nil || maxActiveSessions <= 0 {
		return Config{}, fmt.Errorf("MAX_ACTIVE_SESSIONS must be a positive integer")
	}

	cfg := Config{
		ListenAddress:         envString("LISTEN_ADDRESS", ":8080"),
		DataDir:               envString("DATA_DIR", "/data"),
		AndroidVersion:        envString("ANDROID_VERSION", "17"),
		APILevel:              apiLevel,
		SystemImageKind:       envString("SYSTEM_IMAGE_KIND", "google_apis_playstore_ps16k"),
		KVMAvailable:          kvm,
		RuntimeMode:           envString("RUNTIME_MODE", "registry_only"),
		MaxActiveSessions:     maxActiveSessions,
		PreflightEvidenceFile: strings.TrimSpace(os.Getenv("PREFLIGHT_EVIDENCE_FILE")),
		ProbeFileTemplate:     strings.TrimSpace(os.Getenv("EMULATOR_HEALTH_FILE_TEMPLATE")),
		ProbeURLTemplate:      strings.TrimSpace(os.Getenv("EMULATOR_HEALTH_URL_TEMPLATE")),
		ProbeMaxAge:           time.Duration(probeMaxAgeSeconds) * time.Second,
		ProbeTimeout:          probeTimeout,
		HTTPWriteTimeout:      httpWriteTimeout,
		MinimumLease:          time.Minute,
		DefaultLease:          time.Hour,
		MaximumLease:          24 * time.Hour,
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.ListenAddress) == "" {
		return fmt.Errorf("LISTEN_ADDRESS must not be empty")
	}
	if strings.TrimSpace(c.DataDir) == "" {
		return fmt.Errorf("DATA_DIR must not be empty")
	}
	if strings.TrimSpace(c.AndroidVersion) == "" {
		return fmt.Errorf("ANDROID_VERSION must not be empty")
	}
	if strings.TrimSpace(c.SystemImageKind) == "" {
		return fmt.Errorf("SYSTEM_IMAGE_KIND must not be empty")
	}
	if strings.TrimSpace(c.RuntimeMode) == "" {
		return fmt.Errorf("RUNTIME_MODE must not be empty")
	}
	if c.MaxActiveSessions <= 0 {
		return fmt.Errorf("MAX_ACTIVE_SESSIONS must be a positive integer")
	}
	if c.ProbeFileTemplate != "" && !strings.Contains(c.ProbeFileTemplate, "{id}") {
		return fmt.Errorf("EMULATOR_HEALTH_FILE_TEMPLATE must contain {id}")
	}
	if c.ProbeURLTemplate != "" {
		if !strings.Contains(c.ProbeURLTemplate, "{id}") {
			return fmt.Errorf("EMULATOR_HEALTH_URL_TEMPLATE must contain {id}")
		}
		parsed, err := url.Parse(c.ProbeURLTemplate)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return fmt.Errorf("EMULATOR_HEALTH_URL_TEMPLATE must be an absolute http(s) URL")
		}
	}
	if c.ProbeTimeout <= 0 {
		return fmt.Errorf("PROBE_TIMEOUT_MILLIS must be a positive integer")
	}
	if c.HTTPWriteTimeout <= 0 || c.HTTPWriteTimeout < c.ProbeTimeout || c.HTTPWriteTimeout-c.ProbeTimeout < minimumHTTPWriteTimeoutHeadroom {
		return fmt.Errorf("HTTP_WRITE_TIMEOUT_MILLIS must be at least PROBE_TIMEOUT_MILLIS plus %d", minimumHTTPWriteTimeoutHeadroom/time.Millisecond)
	}
	if c.MinimumLease <= 0 || c.DefaultLease < c.MinimumLease || c.MaximumLease < c.DefaultLease {
		return fmt.Errorf("invalid lease duration bounds")
	}
	return nil
}

func envMilliseconds(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	maximumMilliseconds := int64(time.Duration(1<<63-1) / time.Millisecond)
	if err != nil || parsed <= 0 || parsed > maximumMilliseconds {
		return 0, fmt.Errorf("%s must be a positive integer within the supported millisecond range", name)
	}
	return time.Duration(parsed) * time.Millisecond, nil
}

func envString(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback int) (int, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	return parsed, nil
}

func envBool(name string, fallback bool) (bool, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", name)
	}
	return parsed, nil
}
