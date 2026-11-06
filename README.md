# GameSir Z1 Console Remapper

A small, **Windows PowerShell 5.1** utility to change key assignments stored on a **GameSir Z1** keypad. It communicates with the keypad directly over USB HID, so you do not need the discontinued GameSir G-Core software or a permanent keyboard-remapping driver.

> **Community reverse-engineering project, not affiliated with GameSir.** Tested on one Z1 with USB ID `VID_0C45&PID_7521` and the original keymap identified below. Hardware writes can leave a device with broken key assignments if interrupted or if the firmware differs. Keep another keyboard connected.

## What it does

1. Reads the keypad's factory/reference keymap (`0x07`) and current/active keymap (`0x08`).
2. Waits for you to **tap and release** a key on the **Z1**.
3. Waits for you to **tap and release** the replacement key on your **main keyboard**.
4. If multiple Z1 keys currently send the same keycode, asks you to choose the intended physical key by its original label.
5. Saves a complete 384-byte before/after backup, shows the proposed change, and requires you to type `WRITE` before it sends anything that modifies the keypad.
6. Writes the full configuration to the keypad, then checks the active mapping by reading it back twice. An optional reconnect test checks persistence.

### v3 change: no stray input in the next prompt

The earlier console version observed key-down events through Windows Raw Input, but the same keypress could remain queued in PowerShell's console buffer and appear in the following `Read-Host` prompt. This version **waits for the captured key to be released**, then **flushes queued console key events** before proceeding. It does not install a keyboard hook or suppress input system-wide.

**This input-buffer fix is new and has not yet been hardware-tested.** The earlier v2 read/write flow was reported working on the Z1.

## Requirements

- Windows 10/11 with **Windows PowerShell 5.1** (`powershell.exe`)
- GameSir Z1 connected by USB in PC mode
- A separate keyboard for entering the replacement key and for recovery
- No Python, G-Core, installer, or extra HID drivers

This revision deliberately supports only the known factory layout whose `0x07` reference keymap has SHA-256:

`ADF7946335EBF5648A7044A187291DE4F0FD92C76B5C0987119EE7C62E4DB381`

The utility **refuses to write** if the connected Z1's reference image differs. Other Z1 firmware or board revisions have not been validated. Do not bypass that check without understanding the physical-key layout.

## Quick start

Download or clone this repository. Open **Windows PowerShell** and run the script from its folder.

**Preview (recommended first):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GameSirZ1-Console-Remap.ps1" -PreviewOnly
```

**Apply a remapping:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GameSirZ1-Console-Remap.ps1"
```

At the prompts:

- **Tap and release** the Z1 key you want to change.
- If it has an identical assignment to another Z1 key, choose its **original physical label** from the list shown.
- **Tap and release** the target key on your normal keyboard.
- Review the proposed changes and type **`WRITE`** to program the Z1, or anything else to cancel.

Do not hold a key down while waiting for the next prompt. Avoid typing ahead of a prompt; the utility intentionally clears pending console input during capture.

## Example: Q and W both send W

If the physical **Q** key has already been remapped to **W**, both physical Q and physical W produce the same keyboard event. Windows Raw Input identifies the **device**, not which switch inside it produced the code. The utility therefore prompts you to choose:

```text
Z1 sent: W
Several Z1 keys currently send this SAME value.
  [13] Physical Q key (currently sends W)
  [14] Physical W key (currently sends W)
Enter the number for the PHYSICAL Z1 key you pressed:
```

To change physical Q, enter `13`. Neither the original record number nor a duplicate keyboard output should be used to guess automatically.

## Backups and safety

Before writing, the utility creates a timestamped folder in:

`Documents\GameSirZ1-Backups\Change-YYYYMMDD-HHMMSS-mmm\`

The folder includes:

| File | Contents |
| --- | --- |
| `before.bin` | Active 384-byte keymap before editing |
| `proposed.bin` | Proposed 384-byte keymap |
| `change.json` | Record number, old/new bytes, checksums |
| `immediate-before.bin` | Live backup immediately before the write |
| `after.bin` | Post-write readback, if successful |

The script makes **two identical live reads** before applying a change, writes all seven blocks, and performs **two readbacks** afterward. It never automatically retries a failed write or rolls back a partial write. **The included script does not provide a one-click restore command.** Preserve your backups privately, and do not publish them in your repository.

If a write fails, **stop** and save the output and backups. Do not keep applying the same write blindly.

## Limitations

- Tested with **one Z1 USB firmware/hardware configuration**, not all variants.
- Only a known set of ordinary keyboard and modifier mapping records can be edited. Vendor-defined functions, macros, unknown records, and RGB settings are intentionally protected.
- Some non-US layouts and unusual keyboard keys may not map as their printed legends suggest; the tool uses physical scan codes.
- Duplicate assignments require explicit physical-key disambiguation.
- This script cannot detect the physical switch location independently of the keycode sent by the Z1.
- Changing a mapping is **not** the same as firmware updating; firmware flashing is neither needed nor supported.
- Windows Raw Input still allows normal key events to reach other applications; the console-buffer cleanup only prevents captured keypresses from being consumed by subsequent **PowerShell prompts**.

## Protocol overview

See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the observed USB IDs, read/write commands, report format, and confirmed versus inferred behavior.

## Files

- `GameSirZ1-Console-Remap.ps1` — complete source code, including native HID transport and Raw Input capture implemented using C# compiled in memory by PowerShell's `Add-Type`.
- `docs/PROTOCOL.md` — reverse-engineering notes and safety limitations.
- `.gitignore` — prevents common private backup and binary files from being accidentally committed.

## License

This is indeed AI Slop.
