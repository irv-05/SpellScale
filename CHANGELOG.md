# Changelog

## v0.3.1

Fixes found in a second replay of the paladin's readings, where some temporary effect raised
every Holy number by 40% for a while.

- A temporary boost (a buff or effect that comes and goes) is set aside instead of being read
  as scaling, and the readings on both sides of it are kept. This fixes Seal of Command and
  Seal of Righteousness reading as scaling with block value, after a boost started as a
  shield went on and ended at a level-up.
- Two-stat formulas follow the same rule as one-stat ones: a level-up can raise a spell's
  base, never lower it.
- Once readings have been set aside, a stat is only named after the number has changed at
  least twice between level-ups (three times for two-stat formulas).
- Removed the tick-rounding guess and the loose-rounding fallback. Forever's tooltips round
  once, and the fallback let coincidences through.

## v0.3.0

Fixes found by replaying a real paladin's and shaman's saved readings (`tools/replay.lua`).

- Spells whose base damage grows with your level, as most classic ranks do, are learned
  properly. Readings are compared within a level and the base may step up at level-ups, so
  stats that rise when you level are no longer blamed for it. This fixes results like
  "SP + -54% block value" on Earth Shock. The browser notes "base rises with level".
- A number that changes for some other reason at the same moment as a gear swap (a talent, an
  effect) is no longer pinned on whatever stat moved. Coefficients have to be positive, a stat
  can't account for more than the whole number, and old readings are only set aside where a
  number visibly jumped. This fixes Holy Shield's block chance reading as "-42% AP".
- Both ends of a "46 to 51" range now pool their evidence, so ranges sharpen faster.
- When spell power and healing have only moved together, "SP + 1/3 healing" is listed as a
  possibility too, since it would give a different coefficient.
- The guess that damage-over-time totals are built from rounded ticks now needs four different
  values to agree first. Forever's tooltips don't round per tick, and round numbers like 20%
  and 30% were triggering it.

## v0.2.0

- Reads your talent tree too, including talents you haven't taken, so you can see what a
  talent scales with before spending points. They're tagged "talent, not taken" in the
  browser; search for "not taken" to list them.
- Tooltips are only annotated when their title matches the spell, so a tooltip can never
  show another spell's numbers.

## v0.1.0

- First release: learns spell scaling from your tooltips as your stats change, annotates
  spell tooltips with the coefficients, and lists everything in a browser (`/ss`).
