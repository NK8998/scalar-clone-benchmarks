# Historical results

Raw measurements from the reference box described in `../../ENVIRONMENT.md`.

**These are not a baseline for your machine.** A second devbox indexed the same
6.83 GB pack 3.18x slower. Reproduce the control on your own hardware — that is
what cells A and B of the current experiment are for.

## `midx-ab.csv`

The multi-pack-index A/B, six cells across two dates. Every field is copied
verbatim from the `result.txt` each run wrote.

| column | meaning |
|---|---|
| `build` | `base` = stock release; `midx` = fork build with `--midx` |
| `no_prefetch` | 1 = history deferred to backfill; 0 = history fetched inline during clone |
| `midx` | `on`/`off` = the treatment; `c2` = the inline-prefetch reference cell |
| `clone_s` | `scalar clone` wall time — the part a developer waits for |
| `backfill_s` | `git maintenance run --task=prefetch` wall time |
| `largest_pack_bytes` | the history pack — **the payload control** |

### What it shows

```
midx OFF   869, 914             mean 891.5 s
midx ON    335, 342, 336        mean 337.67 s
                                → 2.64x, −553.8 s
```

The groups do not merely differ on average, they do not **overlap**: the
slowest ON run (342 s) beats the fastest OFF run (869 s) by **527 s** — more
than the entire runtime of an ON run.

### Why it is trustworthy

- `largest_pack_bytes` is **6,827,039,770 in all six rows**. Every cell
  downloaded byte-identical history, so the difference is processing, not
  payload.
- On the cleanest pair (`aug27-on` vs `aug27-off`, same day, adjacent runs) the
  entire final-payload difference is **15,047,596 B** — and the midx file itself
  is **15,012,724 B**. The midx accounts for essentially the whole difference.
- `clone_s` moved in **opposite directions** on the two dates: on 08-27 the ON
  cell cloned *slower* (804 s vs 604 s), on 08-26 *faster* (243 s vs 497 s).
  Backfill nonetheless stayed tightly grouped in both. That is the signature of
  network noise in the clone phase and a real effect in the backfill phase — and
  it is why `clone_s` should not be read as a midx result.

### What it does not show

`clone_s` ranges from **243 s to 982 s** across these rows. That spread is time
of day and network conditions, not configuration. Do not draw conclusions about
clone time from this table.

The `aug27-c2` / inline-prefetch row has `backfill_s` of 9 s only because the
history was already fetched during the clone — it is a reference point for total
cost, not a fast backfill.
