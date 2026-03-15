# Crypto-Shred

A macOS bash script that performs **crypto-erasure** (crypto-shredding) on USB drives and SD cards, with support for **parallel execution** across multiple drives simultaneously.

## What is Crypto-Shredding?

Crypto-shredding is a data destruction technique where data is rendered irrecoverable by **destroying the encryption key** rather than overwriting the data itself. Once the key is gone, the encrypted data on disk is indistinguishable from random noise — no amount of forensic recovery can retrieve it.

This is more effective than traditional multi-pass overwriting for flash-based storage (USB drives, SSDs) because:

- Flash drives use **wear-leveling** and have 10-20% more physical storage than advertised (over-provisioned cells). The OS cannot address every cell, so overwrite methods may miss data.
- Crypto-shredding doesn't depend on reaching every physical cell — if the key is destroyed, **all** data is unrecoverable regardless of where it lives on the chip.

## Why Write Zeros?

The script writes zeros to fill the entire drive **through the encryption layer**. Since the volume is APFS Encrypted, those zeros are written as AES-XTS ciphertext on disk — appearing as random data at the physical level.

This step matters because APFS encryption is **on-demand** — it only encrypts data as it's written. If you simply enable encryption and immediately destroy the key, blocks that were previously free space may still contain old unencrypted data. By filling the drive with zeros through encryption, every addressable block is guaranteed to contain ciphertext before the key is destroyed.

Writing zeros (instead of random data from `/dev/urandom`) is intentional — the encryption layer transforms them into random-looking ciphertext anyway, and `/dev/zero` is significantly faster.

## How It Works

For each selected drive, the script:

1. **Formats as APFS** — clean slate
2. **Encrypts the volume** — using a random 48-byte passphrase (held in memory only, never written to disk)
3. **Fills with encrypted zeros** — ensures every addressable block is ciphertext
4. **Reformats as ExFAT or APFS** — destroys the encryption key permanently

## Usage

```bash
sudo ./crypto-shred.sh
```

> `sudo` is required for disk operations.

The script will:

- Detect all connected external drives and SD cards
- Let you select which ones to shred
- Ask for the final format (ExFAT for cross-platform, or APFS for macOS-only)
- Require you to type `SHRED` to confirm

## Parallel Execution

When multiple drives are selected, the script processes them **all simultaneously** in parallel background jobs. Each drive runs through the full 4-step pipeline independently — you don't wait for one to finish before the next starts.

This makes it practical to crypto-shred an entire batch of USB drives at once.

## Checking Progress

Step 3 (filling with encrypted zeros) is the slowest step — its duration depends on drive size and write speed. The script automatically prints a progress table every 3 minutes. You can also check manually in another terminal:

```bash
ls -lh /Volumes/CryptoShred*/.fill
```

Each drive gets its own `CryptoShred` volume (macOS appends numbers for duplicates: `CryptoShred 1`, `CryptoShred 2`, etc.).

## Examples

### Single drive

```
~/crypto-shred % sudo ./crypto-shred.sh
Crypto-Shred
Encrypt → Fill → Destroy key

Available drives:
  1) /dev/disk6 — Built In SDXC Reader (988.3 MB (988282880 Bytes) (exactly 1930240 512-Byte-Units))
  2) /dev/disk7 — USB Flash Drive (15.6 GB (15640625152 Bytes) (exactly 30548096 512-Byte-Units))
  3) /dev/disk9 — Cruzer (32.0 GB (32015679488 Bytes) (exactly 62530624 512-Byte-Units))

Select drives to shred (e.g. 1 2 3 or all):
> 1

Final format after shred:
  1) ExFAT  (macOS + Windows)
  2) APFS   (macOS only)
Choice [1]: 1

WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED ON:
  • /dev/disk6 — Built In SDXC Reader (988.3 MB (988282880 Bytes) (exactly 1930240 512-Byte-Units))

Type SHRED to confirm:
> SHRED

[disk6] Step 1/4 — Formatting as APFS...
[disk6] Step 2/4 — Encrypting volume (disk11s1)...
[disk6] Step 3/4 — Filling with encrypted zeros (this takes a while)...
[disk6] Step 4/4 — Destroying key — reformatting as ExFAT...
[disk6] Crypto-shred complete.

All 1 drive(s) crypto-shredded successfully.
```

### Multiple drives (parallel)

```
~/crypto-shred % sudo ./crypto-shred.sh
Crypto-Shred
Encrypt → Fill → Destroy key

Available drives:
  1) /dev/disk6 — Built In SDXC Reader (988.3 MB (988282880 Bytes) (exactly 1930240 512-Byte-Units))
  2) /dev/disk7 — USB Flash Drive (15.6 GB (15640625152 Bytes) (exactly 30548096 512-Byte-Units))
  3) /dev/disk9 — Cruzer (32.0 GB (32015679488 Bytes) (exactly 62530624 512-Byte-Units))

Select drives to shred (e.g. 1 2 3 or all):
> all

Final format after shred:
  1) ExFAT  (macOS + Windows)
  2) APFS   (macOS only)
Choice [1]: 1

WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED ON:
  • /dev/disk6 — Built In SDXC Reader (988.3 MB (988282880 Bytes) (exactly 1930240 512-Byte-Units))
  • /dev/disk7 — USB Flash Drive (15.6 GB (15640625152 Bytes) (exactly 30548096 512-Byte-Units))
  • /dev/disk9 — Cruzer (32.0 GB (32015679488 Bytes) (exactly 62530624 512-Byte-Units))

Type SHRED to confirm:
> SHRED

[disk6] Step 1/4 — Formatting as APFS...
[disk9] Step 1/4 — Formatting as APFS...
[disk7] Step 1/4 — Formatting as APFS...
[disk6] Step 2/4 — Encrypting volume (disk11s1)...
[disk9] Step 2/4 — Encrypting volume (disk12s1)...
[disk7] Step 2/4 — Encrypting volume (disk13s1)...
[disk6] Step 3/4 — Filling with encrypted zeros (this takes a while)...
[disk9] Step 3/4 — Filling with encrypted zeros (this takes a while)...
[disk7] Step 3/4 — Filling with encrypted zeros (this takes a while)...

— Progress (11:51:33) —
+---------------+-------+----------------------+---------------+--------+----------+
| Volume        | Disk  | Drive                | Size          | Filled | Progress |
+---------------+-------+----------------------+---------------+--------+----------+
| CryptoShred   | disk9 | Cruzer               | 31805923328 B | 2.5 GB | ~8%      |
| CryptoShred 1 | disk7 | USB Flash Drive      | 15430868992 B | 244 MB | ~1%      |
| CryptoShred 2 | disk6 | Built In SDXC Reader | 988241920 B   | 897 MB | ~95%     |
+---------------+-------+----------------------+---------------+--------+----------+

[disk6] Step 4/4 — Destroying key — reformatting as ExFAT...
[disk6] Crypto-shred complete.
[disk7] Step 4/4 — Destroying key — reformatting as ExFAT...
[disk7] Crypto-shred complete.
[disk9] Step 4/4 — Destroying key — reformatting as ExFAT...
[disk9] Crypto-shred complete.

All 3 drive(s) crypto-shredded successfully.
```

## Requirements

- macOS 10.13+ (APFS support)
- `diskutil` (built-in)
- `openssl` (built-in)

## Limitations

- Flash storage wear-leveling means a small percentage of over-provisioned cells are unreachable by any software method. Crypto-shredding is the best software-based mitigation for this, but physical destruction is the only absolute guarantee.
- Drive write speed is the bottleneck for step 3. USB 2.0 drives can be slow on large capacities.
