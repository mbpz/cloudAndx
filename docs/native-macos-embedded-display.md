# Phase 2D1 embedded display seam

Phase 2D1 is a fixture-backed, dependency-free macOS seam for the audited
scrcpy 4.1 commit `2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0`. It consumes only
already-open `FileHandle` video/control endpoints. It does not discover sockets,
connect ADB, launch a server, start Android, read environment values, or execute
commands.

The documented raw-video profile is `send_device_meta=false`,
`send_codec_meta=true`, with v4.1 session/frame metadata enabled: codec id,
session `[flags,width,height]`, then media `[PTS+flags,size,payload]`. H.264
configuration is fed to VideoToolbox before Annex-B access units are decoded.
The fixture panel is a MetalKit/CoreImage synthetic frame. Its `MTKView` calls
the same `present(pixelBuffer:)` seam used for decoded buffers; it is explicitly
not live Android and does not change the fail-closed lifecycle UI.
It clears the drawable black, aspect-fits and centers the presented buffer, and
uses that buffer's validated dimensions for the matching touch-coordinate map.

The dedicated display test creates a CPU-backed 16×16 BGRA source buffer (no
IOSurface properties, entitlement, or display service), and asks VideoToolbox
for a software H.264 encoder. When the host exposes that encoder it performs a
real encode → SPS/PPS extraction → Annex-B → `ScrcpyH264Decoder` round trip.
Some restricted test sandboxes deny VideoToolbox encoder discovery. Decode
coverage remains mandatory there via an embedded 48-byte Annex-B baseline
fixture containing SPS, PPS, and one IDR frame. It was authored once with the
local `/opt/homebrew/bin/ffmpeg` libx264 encoder from a 16×16 solid `#2a2a2a`
frame, then had NAL type 6 (SEI) removed using ffmpeg `filter_units=remove_types=6`.
Its SHA-256 is
`5ce781747c676c8e417e3a3a70abf97daf030440e3068c721873702ebc2435f8`.
ffmpeg/x264 are fixture-authoring tools only: neither product code nor tests
invoke them or declare them as dependencies. The test supplies its SPS/PPS
configuration and IDR access unit separately, matching the real stream's
configuration/media packet boundary.

This is a strict native-media test, not a mocked decoder test: it needs normal
macOS VideoToolbox/media-service access. The restricted Codex sandbox blocks
the required IOSurface/media service and returns `kVTCouldNotFindVideoDecoderErr`
(`-12906`); execute the display suite in a normal local macOS process for the
functional result. The test does not suppress that error or substitute a fake
decoded frame.

Excluded: ADB/server launch, socket discovery, helper/lifecycle authority, live
Android evidence, latency claims, audio, clipboard, file transfer, source-built
payload integration, signing/notarization, and release readiness.
