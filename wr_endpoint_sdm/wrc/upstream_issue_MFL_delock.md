# Bozza issue upstream — ohwr/project/wrpc-sw

Da aprire su <https://gitlab.com/ohwr/project/wrpc-sw/-/issues> (serve account GitLab).
Verificato il 20/7/2026 che non esistono issue upstream su delock/MFL/lock detector.
Trovato durante il porting WRPC su KR260 (progetto Light Rabbit), ma l'albero softpll è
upstream non modificato: il baco non dipende dal porting.

Dopo il test della fibra (vedi `results/RESULTS_v15.md`), aggiungere l'esito nella sezione
"Observed behaviour" prima di aprire l'issue.

---

**Title:** `softpll: freq_ld delock branch is unreachable (delock_samples > lock_samples) — MFL never clears during operation`

**Labels:** bug

## Summary

The frequency-branch lock detector of the main PLL is configured with
`delock_samples > lock_samples`, which violates the invariant documented in
`spll_common.h` and makes the delock branch of `ld_update()` arithmetically
unreachable. As a result, once the `MFL` flag (reported by `pll stat`) goes to 1
it can never return to 0 through the lock detector; it is only cleared as a side
effect of `ld_init()` inside `mpll_start()`. `MFL1` therefore means "frequency
has locked *at least once since the last `mpll_start()`*", not "frequency is
locked now".

All references below are to current master
[`a9f7580f`](https://gitlab.com/ohwr/project/wrpc-sw/-/commit/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97).

## Details

`ld_update()` ([softpll/spll_common.c#L60-82](https://gitlab.com/ohwr/project/wrpc-sw/-/blob/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97/softpll/spll_common.c#L60-82)) implements hysteresis with a counter:

* good sample: `lock_cnt++`, saturating at `lock_samples`; lock is declared when
  `lock_cnt == lock_samples`;
* bad sample: `lock_cnt--` **only while `lock_cnt > delock_samples`**; delock is
  declared when `lock_cnt == delock_samples && locked`.

This requires `delock_samples < lock_samples`, and the header says so explicitly
([softpll/spll_common.h#L33-34](https://gitlab.com/ohwr/project/wrpc-sw/-/blob/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97/softpll/spll_common.h#L33-34)):

```c
int delock_samples;	/* Accumulated number of samples that causes the PLL go get out of lock.
			   delock_samples < lock_samples.  */
```

The phase branch respects it (`lock_samples = 1000`, `delock_samples = 100`,
[softpll/spll_main.c#L127-129](https://gitlab.com/ohwr/project/wrpc-sw/-/blob/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97/softpll/spll_main.c#L127-129)). The frequency branch does not
([softpll/spll_main.c#L121-123](https://gitlab.com/ohwr/project/wrpc-sw/-/blob/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97/softpll/spll_main.c#L121-123)):

```c
s->freq_ld.threshold = 50;
s->freq_ld.lock_samples = 50;
s->freq_ld.delock_samples = 20000;
```

With these values `lock_cnt` saturates at 50, so both `lock_cnt > 20000`
(decrement) and `lock_cnt == 20000` (delock) can never be true: the entire
`else` branch of `ld_update()` is dead code for `freq_ld`, regardless of how far
the frequency error drifts.

The only path that clears `freq_ld.locked` is `ld_init()` called from
`mpll_start()`
([softpll/spll_main.c#L234](https://gitlab.com/ohwr/project/wrpc-sw/-/blob/a9f7580fc60666a05cdbe6e70f8c56d3a3551f97/softpll/spll_main.c#L234)),
i.e. at bring-up and on the full FSM restart after a *phase* delock.

## History

The invariant has been violated since the frequency prelocking was introduced:

* [`92b55882`](https://gitlab.com/ohwr/project/wrpc-sw/-/commit/92b55882b69b6c2d3a7c3b0c7386d166c6e94658)
  ("softpll: implement frequency prelocking", 2023-11-08) — initial values
  `lock_samples = 50`, `delock_samples = 1000` (already inverted);
* [`d77aca48`](https://gitlab.com/ohwr/project/wrpc-sw/-/commit/d77aca48fd8f7f8018bf85c50bca042fa0916f0b)
  ("softpll: fiddle a bit with freq prelock threshold & PI gain", 2023-11-18) —
  `delock_samples` raised to 20000.

## Impact

* `MFL` in the `pll stat` output is misleading as a health indicator: it stays 1
  while the frequency is arbitrarily far off, until the phase branch delocks and
  the FSM restart re-initializes the detector.
* Anyone monitoring a WR node and treating `MFL0` as "frequency lost" will never
  see the event.
* If the intent was "never delock on frequency, prelock only matters during
  bring-up" (plausible, since `mpll_start()` re-inits the detector anyway), that
  contract is not documented and the `20000` reads as a working threshold.

## Observed behaviour

On our node (WRPC on a Xilinx KR260 carrier, wrpc-sw master `a9f7580`,
softpll unmodified) `MFL1 MPL0` is routinely visible during long acquisition
phases, consistent with the analysis. <!-- TODO dopo il test della fibra:
aggiungere qui l'esito (MPL/MFL dopo lo strappo della fibra a lock acquisito). -->

## Suggested fix

Either:

1. restore the invariant, e.g. `delock_samples = 10` (analogous to the
   1000/100 ratio of the phase branch), so `MFL` actually tracks frequency
   lock; or
2. if frequency delock is intentionally disabled, make it explicit (e.g.
   `delock_samples = -1` with a documented "never delock" meaning, or an assert
   on the invariant in `ld_init()`), so the dead branch cannot be mistaken for a
   working one.

Happy to submit a patch either way.
