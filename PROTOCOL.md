# GameSir Z1 USB HID protocol — reverse-engineering notes

This document records observations on **one** GameSir Z1 (`VID_0C45`, `PID_7521`) in November 2026. It is neither an official specification nor guaranteed to apply to all firmware revisions. **All four G-key remapping records were verified on the user's device**, but the meaning of their original vendor-defined encoding remains unknown.

## Interfaces

- **Keyboard events:** `MI_00`. Windows Raw Input captured G1, G2, G3, G4, Q and W through this same interface.
- **Configuration/control:** `MI_01 COL04`, vendor HID usage page `0xFF1C`, usage `0x0092`.
- **Report ID:** `0x04`; input/output report length: **64 bytes**, including report ID.
- Requests use Windows Win32 overlapped `WriteFile` and queued `ReadFile`, not `HidD_SetOutputReport`.

## Report format

| Byte(s) | Value / purpose |
| --- | --- |
| `0` | HID report ID `04` |
| `1–2` | 16-bit little-endian additive checksum over bytes `3..63` |
| `3` | Command/opcode |
| `4` | Payload length (up to 56 bytes) |
| `5–6` | Byte offset, little-endian |
| `7` | Reserved `00` |
| `8–63` | Data or padding |

The known **384-byte** keymap is transferred as seven chunks: **6 × 56 bytes + 48 bytes**.

## Verified opcodes on this Z1

| Opcode | Observed behaviour |
| --- | --- |
| `0x07` | Read original/reference keymap; unchanged after active remaps. |
| `0x08` | Read current **active** keymap; reflected changed and persisted remaps. |
| `0x01` | Begin transaction used in the working full-image write. |
| `0x09` | Send the seven full-image write chunks. |
| `0x02` | Finish/commit the working full-image write transaction. |

The write transaction uses **`0x01`, seven `0x09` chunks, then `0x02`**. A successful WriteFile completion alone is **not** proof of device acceptance; the utility performs two full active-map readbacks and offers a reconnect check. It never automatically retries.

A separate test of **`0x14`**, which is a macro-read opcode on a different keyboard model, returned a matching report with **56 zero data bytes** on this Z1. This is *not* evidence that a supported macro-storage table exists. The meaning of `0x14` on the Z1 is unverified and it is not used for normal remapping.

## Three-byte record examples

Some of the keymap consists of 3-byte key assignment records:

| Record | Meaning |
| --- | --- |
| `20 00 14` | Q, keyboard HID usage `0x14` |
| `20 00 1A` | W, usage `0x1A` |
| `20 00 2C` | Space, usage `0x2C` |
| `20 00 3F` | F6, usage `0x3F` |
| `20 08 00` | Left Windows modifier mask |
| `20 01 00` | Left Control modifier mask |
| `20 02 00` | Left Shift modifier mask |

The ordinary key record at index **13** (byte offsets 39–41) was proven to change physical Q from Q to W. On the Z1, records **0–3** control the four physical G buttons:

| Index | Reference record | Factory Windows output | Hardware validation |
| ---: | --- | --- | --- |
| `0` | `D0 A2 01` | `8` (`20 00 25`) | G1 changed to F6, then LeftWin |
| `1` | `D0 A2 02` | `9` (`20 00 26`) | G2 physically remapped successfully |
| `2` | `D0 A2 03` | PageUp (`20 00 4B`) | G3 physically remapped successfully |
| `3` | `D0 A2 04` | PageDown (`20 00 4E`) | G4 changed to M, all four keys reported working |

The `D0 A2` records are **special vendor values**, not ordinary HID output codes. They can be replaced with `20 xx xx` records for standard keyboard assignments on the tested hardware; we do **not** know how their original functions are implemented.

**Do not edit every 3-byte group in the 384-byte image.** Only the known factory physical-key indices are permitted. Other groups contain unknown configuration or lookup information. The program preserves all bytes except those in the selected 3-byte record.

## Tested layout guard and safeguards

The original/reference 384-byte `0x07` image on the tested Z1 has SHA-256:

`ADF7946335EBF5648A7044A187291DE4F0FD92C76B5C0987119EE7C62E4DB381`

The application requires that exact hash before remapping and uses **`0x08`** for current changes, backups and readback. It refuses changed reference layouts, writes no more than one selected record, backs up the whole current image, checks a fresh live read twice immediately before writing, and compares two post-write full-image reads. A mismatch or interrupted write is **not** automatically retried or rolled back.

## Reference research

[GeekElite Lio87 WebHID driver](https://github.com/cc2562/GeekElite-Lio87-web-driver) supplied a reference implementation of a similar report envelope, keymap length and read/write framing. This was a **starting point only**: identical report layouts do not imply identical opcode meanings or safe writes on other devices. The Z1 results above came from tests on an actual Z1.
