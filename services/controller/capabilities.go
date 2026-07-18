package main

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const (
	CapabilityReal         = "real"
	CapabilityHighFidelity = "high_fidelity"
	CapabilitySimulated    = "simulated"
	CapabilityBlocked      = "blocked"
)

type PlatformResponse struct {
	AndroidVersion    string `json:"android_version"`
	APILevel          int    `json:"api_level"`
	SystemImageKind   string `json:"system_image_kind"`
	KVMAvailable      bool   `json:"kvm_available"`
	RuntimeMode       string `json:"runtime_mode"`
	LifecycleScope    string `json:"lifecycle_scope"`
	RuntimeManaged    bool   `json:"runtime_managed"`
	ProbeConfigured   bool   `json:"probe_configured"`
	MaxActiveSessions int    `json:"max_active_sessions"`
	EvidenceStatus    string `json:"evidence_status"`
}

type Capability struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	Evidence string `json:"evidence"`
	Caveat   string `json:"caveat,omitempty"`
}

type CapabilitiesResponse struct {
	Platform     PlatformResponse `json:"platform"`
	Capabilities []Capability     `json:"capabilities"`
}

var knownCapabilities = map[string]struct{}{
	"android_framework": {}, "google_mobile_services": {}, "google_play_store": {},
	"adb": {}, "hardware_acceleration": {}, "graphics": {}, "camera": {}, "microphone": {},
	"telephony": {}, "sms": {}, "gnss": {}, "sensors": {}, "wifi": {}, "bluetooth": {},
	"nfc": {}, "uwb": {}, "esim": {}, "ims": {}, "biometrics": {}, "strongbox": {},
	"widevine_l1": {}, "hardware_backed_play_integrity": {},
}

func platformFromConfig(cfg Config) PlatformResponse {
	return PlatformResponse{
		AndroidVersion: cfg.AndroidVersion, APILevel: cfg.APILevel,
		SystemImageKind: cfg.SystemImageKind, KVMAvailable: cfg.KVMAvailable,
		RuntimeMode: cfg.RuntimeMode, LifecycleScope: "lease_registry_only",
		RuntimeManaged:    false,
		ProbeConfigured:   cfg.ProbeFileTemplate != "" || cfg.ProbeURLTemplate != "",
		MaxActiveSessions: cfg.MaxActiveSessions,
		EvidenceStatus:    preflightEvidenceStatus(cfg.PreflightEvidenceFile),
	}
}

func preflightEvidenceStatus(path string) string {
	if path == "" {
		return "unavailable"
	}
	data, err := readLimitedFile(path, 1<<20)
	if err != nil {
		return "unavailable"
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return "unavailable"
	}
	var statusRaw, stateRaw json.RawMessage
	var statusSeen, stateSeen bool
	for decoder.More() {
		name, err := decoder.Token()
		if err != nil {
			return "unavailable"
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return "unavailable"
		}
		switch name {
		case "status":
			if statusSeen {
				return "unavailable"
			}
			statusSeen, statusRaw = true, raw
		case "state":
			if stateSeen {
				return "unavailable"
			}
			stateSeen, stateRaw = true, raw
		}
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || requireJSONEOF(decoder) != nil {
		return "unavailable"
	}
	raw := statusRaw
	if !statusSeen {
		// The companion evidence-gate calls this field "state". Supporting it
		// keeps the read-only integration honest while preferring "status".
		if !stateSeen {
			return "unavailable"
		}
		raw = stateRaw
	}
	var status string
	if err := json.Unmarshal(raw, &status); err != nil {
		return "unavailable"
	}
	allowed := map[string]struct{}{
		"PASS": {}, "FAIL": {}, "BLOCKED": {}, "DESIGN_READY": {},
		"KVM_READY": {}, "SOFTWARE_EMULATION_ONLY": {},
	}
	if _, ok := allowed[status]; !ok {
		return "unavailable"
	}
	return status
}

func capabilitiesFromConfig(cfg Config) CapabilitiesResponse {
	playImage := isGooglePlayImageKind(cfg.SystemImageKind)
	googleStatus := CapabilityBlocked
	googleEvidence := "SYSTEM_IMAGE_KIND does not identify a Google Play system image"
	if playImage {
		googleStatus = CapabilityHighFidelity
		googleEvidence = fmt.Sprintf("SYSTEM_IMAGE_KIND=%s declares a recognized SDK Google Play image family", cfg.SystemImageKind)
	}

	kvmStatus := CapabilityBlocked
	kvmEvidence := "KVM_AVAILABLE=false; accelerated Android runtime is not proven"
	if cfg.KVMAvailable {
		kvmStatus = CapabilityReal
		kvmEvidence = "KVM_AVAILABLE=true was supplied by the deployment after host/device validation"
	}

	virtual := func(id string) Capability {
		return Capability{ID: id, Status: CapabilitySimulated, Evidence: "Android Emulator exposes a virtualized implementation", Caveat: "not equivalent to physical-device hardware"}
	}
	blockedHardware := func(id, reason string) Capability {
		return Capability{ID: id, Status: CapabilityBlocked, Evidence: reason, Caveat: "requires a certified physical-device lane for complete coverage"}
	}

	items := []Capability{
		{ID: "android_framework", Status: CapabilityHighFidelity, Evidence: fmt.Sprintf("configured Android %s / API %d SDK system image", cfg.AndroidVersion, cfg.APILevel), Caveat: "runtime availability still requires a verified session probe"},
		{ID: "google_mobile_services", Status: googleStatus, Evidence: googleEvidence, Caveat: "image declaration is not a redistribution license or physical certification"},
		{ID: "google_play_store", Status: googleStatus, Evidence: googleEvidence, Caveat: "Play Store behavior depends on an actually available licensed image and account access"},
		{ID: "adb", Status: CapabilityHighFidelity, Evidence: "standard Android Emulator interface", Caveat: "usable only after external runtime startup and verified health"},
		{ID: "hardware_acceleration", Status: kvmStatus, Evidence: kvmEvidence},
		virtual("graphics"), virtual("camera"), virtual("microphone"), virtual("telephony"),
		virtual("sms"), virtual("gnss"), virtual("sensors"), virtual("wifi"), virtual("bluetooth"),
		blockedHardware("nfc", "generic Android Emulator does not provide complete physical NFC behavior"),
		blockedHardware("uwb", "generic Android Emulator does not provide a physical UWB radio"),
		blockedHardware("esim", "generic Android Emulator does not provide a carrier-backed eSIM/eUICC"),
		blockedHardware("ims", "generic Android Emulator does not provide complete carrier IMS service"),
		blockedHardware("biometrics", "emulator biometric events are simulated, not a physical biometric trust path"),
		blockedHardware("strongbox", "no certified physical StrongBox secure element is present"),
		blockedHardware("widevine_l1", "Widevine L1 requires a certified hardware-backed DRM path"),
		blockedHardware("hardware_backed_play_integrity", "hardware-backed Play Integrity cannot be represented as a generic Docker emulator guarantee"),
	}
	return CapabilitiesResponse{Platform: platformFromConfig(cfg), Capabilities: items}
}

func isGooglePlayImageKind(kind string) bool {
	switch kind {
	case "google_apis_playstore", "google_apis_playstore_ps16k":
		return true
	default:
		return false
	}
}
