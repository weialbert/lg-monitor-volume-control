# LG Monitor Volume Control

Native macOS monitor hardware volume control with direct DDC and routed MST support.

The menu bar app routes macOS volume keys to an attached display's hardware volume when that display is selected as the current audio output. It does not depend on BetterDisplay. It discovers direct DDC displays and single-hop DisplayPort MST downstream displays, using the matching transport without a dock-model selector.

## Build and use

Requirements: macOS 14 or later, Apple command line developer tools, and a display that exposes DDC/CI volume. A full Xcode installation is not required.

```sh
swift run protocol-self-test
swift build --product lg-monitor-cli
./.build/debug/lg-monitor-cli list
./scripts/build-app.sh
open "build/LG Monitor Volume.app"
```

The CLI supports `list`, `doctor`, `get-volume <id>`, `get-mute <id>`, `set-volume <id> <value>`, and `mute <id> true|false`. `list`, `doctor`, and the `get-*` commands only query the monitor. The app's menu provides monitor selection, a hardware-volume slider, mute when the display reports a known mute state, and launch-at-login. Grant Accessibility access when prompted so the app can capture volume-key events. It consumes those events only while its selected display matches the system's default audio output; other outputs keep normal macOS key behavior.

The bundle produced by the script is locally ad-hoc signed for development and is not notarized. A distributed release should be signed and notarized by its publisher.

The monitor route is discovered at runtime from the external display service and DisplayPort topology; transport selection does not use a dock vendor, dock model, or BetterDisplay state. The MST parser currently handles a single downstream hop; nested MST branches are outside this first release. The implementation has been exercised on the hardware described below. Other display bridges and docks still need compatibility testing. The DDC and DPCD calls use dynamically loaded private macOS IOKit APIs, so a macOS update could change them. No universal dock matrix has been verified.

# LG Monitor Volume Control — confirmed routing cause

The failing DDC path is the dock's **unrouted I²C-over-AUX interface**. The same monitor on the same cable and port answers volume and brightness queries when they are sent as **port-addressed MST remote-I²C messages to downstream port 1**. This is a demonstrated transport/routing mismatch on this machine, not an inference from another Mac or monitor.

The direct native API returns `0xe0114000`. Inspection of this Mac's installed DCP firmware identifies that status as its I²C-NACK result. Explicit downstream routing succeeds without enabling MST, enabling vendor remote control, changing monitor settings, or using BetterDisplay.

## Hardware and identity

- MacBook Air `Mac14,15`, Apple M2; macOS `27.2`, build `26B123`; native arm64 probes.
- HP Thunderbolt Dock G2, branch `SYNAS3`, Synaptics OUI `90:cc:24`.
- Chip reports `VMM5333`, firmware bytes `05 03 09` (`5.03.09`); board ID `0x0351` (849).
- LG QHD: vendor `0x1e6d`, product `0x7729`, serial recorded in local diagnostic captures; EDID identity bytes `<vendor/product/serial identity>`.
- LINK_ADDRESS reports input port 0; connected output port 1 has peer type 4 (legacy sink), `DDPS=1`, legacy plug status 1; ports 2 and 3 are unconnected.
- The successful routed EDID reads have a valid base-block checksum and match the LG's vendor/product/serial. The exact retail label is not encoded in the exposed identity and is not needed to establish this routing result.

## Controlled evidence

| Test on the same connection | Result |
|---|---|
| Native `IOAVServiceWriteI2C(0x37, 0x51, [82 01 62 de])` | I²C NACK |
| Native complete raw packet `[51 82 01 62 de]`, no register-offset prefix | I²C NACK |
| Routed Get VCP prepares the LG's volume reply, then native read tries to fetch it | I²C NACK |
| Port-addressed remote-I²C read fetches that prepared reply | Valid DDC checksum, supported volume VCP, current 100 / maximum 100 |
| Routed brightness Get VCP | Valid DDC checksum, current 100 / maximum 100 |
| BetterDisplay stopped | Same native failure and routed success |
| BetterDisplay explicitly running | Same native failure and routed success |
| `MSTM_CAP` at `0x021` | `00`, despite the working sideband query |
| `MSTM_CTRL` at `0x111`, before and after | `00`; MST was never enabled |
| Vendor diagnostic state at `0x4b1`, final reproduction before and after | `00`; vendor diagnostic mode is not required |

The raw-packet test excludes the native API's offset-prefix framing as a sufficient explanation. The prepared-reply comparison excludes monitor response readiness as a sufficient explanation. Routed volume responses establish that the monitor's DDC volume feature is reachable and supported through this exact physical connection. Native I²C requests contain no downstream port selector; MST remote-I²C messages contain that missing selector.

This identifies the operational cause of the failed queries. It does not claim a specific undocumented VMM5333 firmware conditional or distinguish whether its native-path behavior is an intentional policy or a firmware defect. No firmware update is needed for the demonstrated working query path.

The initial conclusion that physical rewiring was necessary was premature: a working software route exists even when MST capability and enable bits are clear.

## Byte-level successful volume query

DDC request bytes on downstream I²C: `51 82 01 62 de`.

MST REMOTE_I2C_WRITE body:

```text
23 10 37 05 51 82 01 62 de
```

`23` is the remote write opcode, `10` selects downstream port 1, `37` is the 7-bit DDC/CI slave, and `05` is the payload length. The reply body `23 01` acknowledges the write on port 1.

MST REMOTE_I2C_READ body:

```text
22 10 37 0b
```

The returned MST body is:

```text
22 01 0b 6e 88 02 00 62 00 00 64 00 64 d6
```

Its 11-byte DDC payload is `6e 88 02 00 62 00 00 64 00 64 d6`: Get VCP reply, result 0 (supported), feature `0x62`, maximum 100, current 100. XOR of the complete payload with seed `0x50` is zero. The enclosing MST frame CRCs also validate.

The read-only investigation did not send Set VCP. The application now uses Set VCP `0x62` for absolute volume control and requires a valid DDC reply that reads back the requested value before reporting success. A reversible live check changed the LG from 100 to 99 and restored it to 100 through the routed path.

## Implementation notes

The monitor's audio device exposes no standard CoreAudio scalar-volume or mute properties at the main/stereo output elements. macOS therefore has no volume device for its ordinary keys to control. The menu bar app captures those key events with an Accessibility event tap and maps them to DDC only while the selected monitor matches the default audio output.

The low-level native failure was traced through user-client selector `0x19`, kernel `DCPAVServiceProxy::writeI2C`, and DCP RPC opcode 10. The installed DCP firmware maps the controller status to `0xe0114000`; its handler references `aborting due to I2C_NACK`. Separate AUX-NACK handling uses `0xe0114100`. Firmware binaries and raw machine captures are excluded from this project. They were used to establish the diagnosis on this Mac.

The packet self-check covers the recorded DDC volume reply, checksum, parsed values, corrupted payload, and wrong feature. The diagnostic and firmware extraction artifacts are local investigation materials and are not part of the public source tree.

## Protocol sources

- [Linux MST sideband encoding, topology parsing, and remote-I²C](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/display/drm_dp_mst_topology.c).
- [Linux DP register definitions](https://github.com/torvalds/linux/blob/master/include/drm/display/drm_dp.h).
- [fwupd Synaptics mailbox and identity definitions](https://github.com/fwupd/fwupd/blob/main/plugins/synaptics-mst/fu-synaptics-mst.rs).

These sources explain the protocol. The captured native-versus-routed experiments above establish the cause on this Mac.
