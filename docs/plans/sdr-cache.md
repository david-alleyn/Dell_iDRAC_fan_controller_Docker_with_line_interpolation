# Plan: cache the iDRAC sensor list (SDR) to make temperature reads cheaper

Status: proposed, not started.

## Problem

Each loop runs one `ipmitool sdr type temperature` over lanplus. The expectation
(still to be verified, see step 1) is that every such call:

1. opens a new RMCP+ session (several round trips before any command runs), and
2. downloads the iDRAC's sensor list (the SDR repository) before it can read any
   values. That takes many more round trips, and the list is the same every time.

The healthcheck repeats the same read every 30s, in its own session. All this
round-trip traffic makes the reads slow and loads the iDRAC, and that is when
reads fail ("Unable to establish IPMI v2 / RMCP+ session").

## Idea

The sensor list only changes when hardware changes, so download it once and
reuse it:

```sh
ipmitool <args> sdr dump "$SDR_CACHE_FILE"                         # once, at startup
ipmitool <args> -S "$SDR_CACHE_FILE" sdr type temperature          # every read
```

With `-S`, ipmitool should take the sensor list from the file and fetch only the
live readings from the iDRAC.

## Steps

### 1. Check it on the real iDRAC (Gen 13) before changing any code

Run against the real server, not the mock:

- [ ] `time ipmitool <args> sdr type temperature`, repeated about 5 times. Note the average.
- [ ] `ipmitool <args> sdr dump /tmp/sdr.cache` succeeds and creates the file.
- [ ] `time ipmitool <args> -S /tmp/sdr.cache sdr type temperature`, repeated about 5
      times. It should be clearly faster.
- [ ] `diff` the output with and without `-S`. Apart from the readings
      themselves, it must be identical: same lines, sensor names, `3.1`/`3.2`
      entity IDs and `NN degrees C` format, because `retrieve_temperatures`
      depends on all of these.
- [ ] Optional: count the packets of each command with `tcpdump -i any udp port 623`.

If it isn't measurably faster, or the output differs in a way that breaks
parsing, stop here and record the result in this file.

### 2. Build the cache at startup (`functions.sh`, `Dell_iDRAC_fan_controller.sh`)

- Add `SDR_CACHE_FILE` (default `/tmp/idrac_sdr.cache`; containers start with an
  empty `/tmp`, so every start builds a fresh cache).
- Add `build_sdr_cache`. It runs `sdr dump` into a temporary file and moves it
  into place only if the dump succeeded and the file isn't empty, so a cache is
  never half-written. It returns non-zero on failure.
- Add a global `SDR_CACHE_ARGS` array: `(-S "$SDR_CACHE_FILE")` when the cache
  exists, `()` otherwise.
- Call it once after `set_iDRAC_login_args` and before the first read in
  `Dell_iDRAC_fan_controller.sh`. If the dump fails, log a warning and carry on
  without the cache. A cache failure must never stop the controller.

### 3. Use the cache for reads (`retrieve_temperatures`)

- `ipmitool "${IPMITOOL_ARGS[@]}" "${SDR_CACHE_ARGS[@]}" sdr type temperature`
- Fan write commands (`raw ...`) stay as they are; the cache doesn't affect them.

### 4. Handle a stale cache

The cache can stop matching the hardware (e.g. after an iDRAC firmware update or
hardware change while the container is running):

- If `temperatures_are_valid` fails on **3 reads in a row** while the cache is in
  use, delete the cache, rebuild it (or run without it if rebuilding fails), and
  log this.
- The loop's existing retry behaviour stays the same: an invalid read changes
  nothing and is retried on the next interval.

### 5. Healthcheck (`healthcheck.sh`)

- If `$SDR_CACHE_FILE` exists, pass `-S` to it as well. The healthcheck runs in
  the same container, so it can read the same file.
- If the file is missing, run without `-S`. The healthcheck must never build the
  cache itself (that would mean two processes writing the same file).

### 6. Tests (`tests/run.sh`)

Using a stubbed `ipmitool` function, as the existing fan-command tests do:

- [ ] `build_sdr_cache` success: `SDR_CACHE_ARGS` contains `-S <file>`.
- [ ] `build_sdr_cache` failure (stub returns non-zero): `SDR_CACHE_ARGS` is
      empty, and no cache file is left behind.
- [ ] `retrieve_temperatures` passes `-S <file>` only when the cache exists.
- [ ] Stale cache: 3 invalid reads in a row trigger exactly one rebuild, and a
      valid read resets the counter.

Then an end-to-end run against the scratchpad mock `ipmitool` (extended to
support `sdr dump`), and finally a run against the real iDRAC that checks the
temperature table matches readings taken without the cache.

### 7. Docs

- README: one short note that the sensor list is cached at startup, and that
  restarting the container rebuilds it.

## Out of scope / rejected

- **Grouping the two fan write commands into one session with `ipmitool exec`.**
  Writes are now only sent when the speed changes, so the saving is negligible.
  Revisit only if step 1 shows that opening sessions is the main cost.
- **One long-running `ipmitool shell` session for the whole run.** There's no
  reliable way to tell where one command's output ends, idle sessions time out,
  and recovering from a dropped session in Bash is fragile.
- **Changing `CHECK_INTERVAL`**: the user's decision is to keep it as is.
- **Any Gen 14+ handling**: this fork only supports Gen 13.

## Risks

- `-S` might behave differently on this iDRAC firmware. Step 1 checks this
  before any code is written.
- A stale cache could return no readings or wrong ones. Step 4 makes it rebuild
  automatically, and the existing number check stops bad readings from reaching
  the fan logic.
