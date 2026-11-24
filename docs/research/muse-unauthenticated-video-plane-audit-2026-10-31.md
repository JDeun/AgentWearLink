# Muse control-plane versus unauthenticated video-plane audit (2026-10-31)

## Material security finding
`esp32/components/muse/muse_video_wifi.c:53-56` **explicitly labels its video TCP listener unauthenticated**. `accept_client` (:273-310) accepts a TCP peer without a token, Noise handshake or device authorization; an active sender holds the one-client slot for 10s and new peers are rejected. The first complete message must arrive within 5s. Video input has codec/size validation and bounded buffering, but these are resource protections, **not authentication**.

Threat: any network peer able to reach the listener may attempt to send video or monopolize the video slot while the feature is enabled. Scope is the optional phone->device video receiver, not the authenticated Home Link command channel; no proof of exploit, internet exposure or compromise beyond this trust boundary.

## Additional source observations
- `esp32/components/muse/muse_link.c` abstracts firmware-owned Link callbacks, state changes and Wi-Fi power levels; the UI can request command cancellation, but the bridge does not itself establish a security principal.
- `esp32/components/muse/muse_account_api.c` fetches VM metadata using a bearer device token and returns a VM token; 15s HTTP timeout, bounded response allocation. The token is privileged credential material.
- `esp32/components/muse/muse_state.c` provides UI state, caption and power state with FreeRTOS synchronization.
- `esp32/components/muse/muse_input.c` handles physical button gestures with bounded event queue; when full it invalidates the entire call gesture rather than leaving a partial DOWN/UP sequence. Power-off calls `muse_voice_shutdown(3000)` first; physical power may still cut off before server confirmation.

## AWL decisions
1. **EXCLUDE** unauthenticated media listener from any AWL camera/audio/action surface. Use authenticated, scoped media sessions, explicit user initiation and replay-safe session IDs (#637).
2. **BORROW** bounded, atomic gesture handling: input DOWN/UP must be correlated; on queue saturation, fail the gesture rather than generate an accidental action (#635).
3. **REFERENCE** shutdown ordering: request server-side cleanup before device power-down, with bounded best-effort and eventual retry (#634).
4. **KEEP** AWL's separate agent/device trust boundaries; do not treat network adjacency or device pairing as permission to invoke agent actions.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_video_wifi.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_input.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_account_api.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_link.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_state.c

## Limit
Static code evidence, not network penetration test or hardware runtime confirmation. No AWL production code changed.
