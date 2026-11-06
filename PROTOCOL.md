# Z1 USB HID protocol observations

These notes document **observations on one GameSir Z1**. The protocol is proprietary and may differ across hardware revisions. Nothing here should be treated as official GameSir documentation.

## Confirmed USB interfaces

- USB VID/PID: `0C45:7521`
- Vendor HID collection: `MI_01 COL04`
- HID usage page/usage: `0xFF1C / 0x0092`
- Input and output HID Report ID: `0x04`
- Total report size: 64 bytes (including report ID)

A separate keyboard collection (`MI_00`) exposes feature reports, but the working keymap communication uses the vendor-defined collection through Win32 `WriteFile` and `ReadFile`.

## Packet layout

The observed request and response envelope is 64 bytes:

| Byte(s) | Field |
| --- | --- |
| 0 | Report ID `0x04` |
| 1–2 | 16-bit little-endian additive checksum of bytes 3–63 |
| 3 | Command byte |
| 4 | Requested data length or transmitted data length |
| 5–6 | Little-endian byte offset |
| 7 | Reserved `0x00` |
| 8–63 | Data or zero padding |

Response headers were observed to match their corresponding read requests. The 384-byte keymap is transferred as seven blocks: six of 56 bytes and one of 48 bytes.

## Command observations

| Opcode | Observed behavior |
| --- | --- |
| `0x07` | Returns reference/original 384-byte keymap. Remained unchanged after a Q-to-W remapping. |
| `0x08` | Returns the **active** 384-byte keymap. Reflected the persisted Q-to-W remapping. |
| `0x01` | Used by the existing, user-tested full-image write sequence as transaction begin. |
| `0x09` | Used for seven full-image configuration-write chunks. |
| `0x02` | Used as transaction end/commit in the user-tested persistent write sequence. |

**Do not generalize these to other keyboard models merely because they share HID usage values.**

## Mapping records

The first part of the configuration contains ordinary three-byte mapping records:

- `20 00 14` — `Q` (USB HID keyboard usage `0x14`)
- `20 00 1A` — `W` (usage `0x1A`)
- `20 00 2C` — `Space` (usage `0x2C`)
- `20 00 29` — `Escape` (usage `0x29`)
- `20 01 00` — left Control modifier
- `20 02 00` — left Shift modifier

Other records include vendor-defined values such as `D0 A2 01` and non-key data. The tool preserves those bytes exactly.

The specific tested reference image hash is embedded in the script as a **revision/layout safety guard**. Its contents are not bundled in this repository.

## Read/write validation history

- The original 384-byte image was read over `0x07` and cross-checked across multiple request sizes.
- After a single Q-to-W persistent remapping, the `0x07` image still showed Q; `0x08` reported W.
- The owner confirmed that the direct-write remapping **persisted after reconnecting the Z1**.
- The v2 console workflow was reported working; v3 adds **key-release tracking plus console input-buffer flushing** to prevent keys captured via Raw Input from spilling into the next prompt.

The v3 input-capture change has not yet been exercised against the physical hardware. The protocol observations concern only this hardware configuration.

## Important safety note

Writing only a partial keymap or using a mismatched layout may disable keys. The script writes the whole verified 384-byte configuration and performs readback checks; it does not guarantee recovery from a power interruption or unsupported firmware. Backups should not be committed to a public repository.
