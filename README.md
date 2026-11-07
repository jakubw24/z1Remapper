# GameSir Z1 Console Remapper

A small, **Windows PowerShell 5.1** utility to permanently change key assignments stored on a **GameSir Z1** gaming keypad. It communicates directly over USB HID, so there is no need for the discontinued GameSir G-Core software, Python, an installer, a permanent background process, or a keyboard interception driver.

> **Independent reverse-engineering project, not affiliated with GameSir.** Hardware-tested on one Z1 with USB ID `VID_0C45&PID_7521` and the reference keymap identified below. A failed or interrupted configuration write can leave key assignments unusable. Keep a second keyboard connected.

## What it does

1. Reads the Z1's reference (`0x07`) and **current active** (`0x08`) 384-byte keymaps.
2. Asks you to **tap and release** the physical key on the **Z1** that you want to change, including **G1, G2, G3 and G4**.
3. If several keys currently produce the same output, asks you to select the intended **physical** key rather than guessing.
4. Asks you to **tap and release** the replacement key on your regular keyboard.
5. Saves timestamped binary backups, displays the exact proposed edit, and requires a deliberate `WRITE` confirmation before changing hardware.
6. Writes the full 384-byte configuration and verifies it by reading the active keymap back twice. It offers an optional reconnect/persistence check.

The utility waits for each captured key to be **released** and clears pending **PowerShell console input** so captured keystrokes do not appear at the next prompt. It does **not** suppress keystrokes in other applications.

## Requirements

- Windows 10/11 with **Windows PowerShell 5.1** (`powershell.exe`)
- A GameSir Z1 connected by USB in PC mode
- A **second keyboard** for replacement-key capture and recovery
- The tested Z1 reference keymap (see the compatibility guard below)

No additional driver, Android app, Python installation or G-Core is required.

## Quick start

Download or clone this repository, open Windows PowerShell in its directory and run:

**Preview without writing:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GameSirZ1-Console-Remap.ps1" -PreviewOnly
```

**Apply a remapping:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GameSirZ1-Console-Remap.ps1"
```

Tap and release the Z1 key, select a physical-key label only if prompted, then tap and release the replacement key on your **main keyboard**. Check the proposed record and type `WRITE` to save, or anything else to cancel.

You can also capture G-button diagnostic output **without writing**:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GameSirZ1-Console-Remap.ps1" -DiagnoseGKeys
```

The older `-EnableExperimentalGKeys` option is still accepted for compatibility, but **is no longer needed**. G1–G4 all use the normal `WRITE` confirmation.

## G1–G4: physically tested

All four G-buttons have now been remapped successfully on the tested Z1. Their physical keys correspond to the first four 3-byte records in the keymap:

| Physical button | Factory special record | Record index | Observed factory output | Verification |
| --- | --- | ---: | --- | --- |
| **G1** | `D0 A2 01` | `0` | `8` (`20 00 25`) | Remapped to **F6**, later **Left Windows** |
| **G2** | `D0 A2 02` | `1` | `9` (`20 00 26`) | User confirmed successful physical remapping |
| **G3** | `D0 A2 03` | `2` | **PageUp** (`20 00 4B`) | User confirmed successful physical remapping |
| **G4** | `D0 A2 04` | `3` | **PageDown** (`20 00 4E`) | Remapped to **M** in the experiment; all four subsequently reported working |

**PageUp/PageDown are not Up/Down arrows.** USB HID usages for Up and Down are `0x52` and `0x51`. The special `D0 A2 xx` records can be replaced with ordinary keyboard records for the tested device. Their *original vendor-defined semantics* are still unknown; assigning a key such as `8` is not equivalent to restoring a factory `D0 A2` special record.

For a factory-special G record still present in the active map, selection uses the **previously observed default Windows output**. Once remapped, it uses that G-button's ordinary stored assignment. If a key instead sends an unsupported macro or other non-keyboard sequence, the utility may refuse to select it rather than risk editing the wrong record.

## Duplicate assignments

If physical Q is remapped to W, pressing either Q or W sends the same event. Windows Raw Input identifies which **keyboard device** produced it, not the particular switch inside that keyboard. The utility therefore asks which original physical key you pressed:

```text
Z1 sent: W
Several Z1 keys currently send this SAME value.
  [13] Physical Q key (currently sends W)
  [14] Physical W key (currently sends W)
Enter the number for the PHYSICAL Z1 key you pressed:
```

Only the selected record changes.

## Backups and safety

Before any hardware modification, the utility saves a timestamped folder under:

`Documents\GameSirZ1-Backups\Change-YYYYMMDD-HHMMSS-mmm\`

| File | Contents |
| --- | --- |
| `before.bin` | Active 384-byte keymap before editing |
| `proposed.bin` | Proposed 384-byte keymap |
| `change.json` | Record number, before/after bytes, SHA-256 hashes |
| `immediate-before.bin` | Fresh live backup immediately before a confirmed write |
| `after.bin` | Post-write readback if available |

**Important safeguards:** the script reads the active image twice initially and again immediately before the write; changes **at most one known 3-byte record**; writes the full image as seven chunks; and checks the active image twice after writing. It does **not** automatically retry or roll back unsuccessful writes. **There is no general-purpose restore command.** Preserve backups privately and do not upload them to GitHub.

The tested reference-image SHA-256 (`0x07`) is:

`ADF7946335EBF5648A7044A187291DE4F0FD92C76B5C0987119EE7C62E4DB381`

The utility refuses to operate if the connected Z1's reference image differs. This protects against unknown layouts but also means other Z1 firmware/board versions are **not yet supported**.

If a write fails, **stop and retain the logs and backups**. Do not blindly rerun the write. A USB reconnect does not guarantee recovery from a damaged onboard configuration.

## Limitations

- Tested on **one Z1 configuration**, not every firmware revision or game mode.
- Ordinary keys and **G1–G4** have been physically remapped on the tested unit; original vendor-defined G-function encoding is not understood.
- Macros, RGB functions, mouse actions, unsupported layers and complex multi-key output are **not** editable through this console utility.
- Keyboard scan-code translation may not match printed legends on non-US layouts or unusual keyboards.
- If a key produces an unsupported output, the tool refuses to guess the physical record.
- Windows Raw Input does not prevent the same key event reaching other applications.
- The full-image write has device-level risk even with checks and backups; restoration is not guaranteed.

## Protocol and source files

- [`GameSirZ1-Console-Remap.ps1`](GameSirZ1-Console-Remap.ps1) — complete single-file application, including Win32 HID and Raw Input interop compiled at runtime via PowerShell `Add-Type`.
- [`PROTOCOL.md`](PROTOCOL.md) — observed packet format, keymap structure, command usage and G1–G4 experiments.
- [`.gitignore`](.gitignore) — exclusions for private keymap dumps, backups and temporary files.

The earlier repository also contained a file named `download` holding ignore-pattern text. It was **not** a real `.gitignore`; this update includes the correctly named file. You may delete the old `download` file from GitHub after uploading this release.

## License

No open-source license has been selected or included. Add a `LICENSE` file if you intend to grant explicit rights to reuse, modify and redistribute this work.

*Original README note: “This is indeed AI Slop.”*
