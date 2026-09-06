# Prior experiments

How to reproduce everything measured before the current experiment. Each file
states what was being tested, how it was run, what came out, and — where it
matters — what the result does **not** prove.

| file | question |
|---|---|
| `01-midx-ab.md` | Does a multi-pack-index over the shared cache speed up backfill? |
| `02-backfill-race.md` | Why doesn't background backfill start after a clone? |
| `03-clone-phase.md` | Can the foreground clone itself be made shorter? |

`harnesses/run-midx.sh` is the script the `01` runs actually used, kept verbatim
rather than tidied, so published numbers stay traceable to the exact code that
produced them.

Raw records are in `../results/historical/`.

---

## Reading these honestly

Two labels are used throughout, and the distinction matters:

- **measured** — a wall-clock number from a run whose `result.txt` is in
  `../results/historical/`.
- **composed** — a number obtained by *adding* measured parts, sometimes with an
  assumed gap between them. Composed figures are estimates. Several
  widely-quoted totals are composed, including the headline "2h43m", and the
  current experiment's cell D exists to replace the most important of them with
  a real measurement.

Anything not backed by a `result.txt` is called out where it appears.
