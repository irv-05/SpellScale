# SpellScale

A World of Warcraft: Forever addon that learns how your spells scale with spell power, attack
power and your other stats while you play. It then writes the coefficients into your spell
tooltips, the way modern games show them:

> Hurls a fiery ball that causes 87 to 96 **(42.9% Fire SP)** Fire damage and an additional 36 **(20% Fire SP)** Fire damage over 4 sec.

Nothing is datamined or hardcoded. Every number is worked out from your own character, so it
stays correct as Blizzard tunes spells during the beta.

## Why it works this way

Forever runs retail's Midnight-era addon rules. Addons can't read the combat log, and damage
numbers are hidden from them, so "watch the damage and work backwards" isn't possible.

Forever's spell tooltips are live, though: the numbers in them already include your current
spell power. So whenever your stats change (gear, buffs, levels), SpellScale reads the
description of every spell in your spellbook and talent tree, and stores the numbers next to a
snapshot of your stats. That turns out to be better than damage logs anyway. Tooltips have no
crits, resists or random damage rolls in them, just rounding.

## How it learns

Every number in a tooltip is a formula, `base + coefficient × stat`, rounded to a whole number.
For each stat it might depend on, SpellScale works out the exact range of coefficients that
reproduces every reading it has seen. For example:

- Your spell power goes from 100 to 105 and Fireball goes from 150 to 152. Rounding could hide
  up to a point of difference, so the coefficient is anywhere from about 20% to 60%.
- Your spell power goes from 100 to 300 and Fireball goes from 150 to 236. Now it's between
  42.5% and 43.5%.

Each reading narrows the range further. A stat that doesn't explain the numbers runs out of
possible coefficients as soon as your gear moves stats in a different proportion, which is how
the addon tells spell power apart from intellect, healing, and so on.

Many classic spells also gain base damage as you level, until the rank tops out. Your stats
rise at a level-up too, so SpellScale compares readings taken at the same level, and lets the
base step up between levels. It also keeps two rules every tooltip follows: numbers grow with
stats, and a stat can't account for more than the whole number.

The stats it considers: spell power (overall and per school), bonus healing, spell power plus
a third of bonus healing (Forever's healing-to-damage rule), attack power, ranged attack
power, main-hand weapon damage, shield block value, strength, agility, stamina, intellect,
spirit, and character level.

## Reading the annotations

| Annotation | Meaning |
|---|---|
| `(42.9% SP)` | Learned, precise to a tenth of a percent |
| `(43% SP)` | Learned; your stats haven't spread far enough yet for a decimal |
| `(~43% SP)` | Still rough (more than ±5%); sharpens as your stats spread out |
| `(43% SP?)` in gold | It scales, but your gear has only ever moved two stats together (say spell power and healing) |
| `(+2.0 per level)` | Scales with character level rather than a stat |
| `(25% Holy SP + 15% AP)` | Scales with two stats at once |

Numbers that don't scale, like durations and ranges, are left alone.

## Talents

SpellScale reads your whole talent tree the same way, including talents you haven't taken, so
you can see what a talent scales with before you spend points on it. The annotations show up
in the talent window's tooltips too.

## Teaching it faster

- **Change one thing at a time.** Swap a ring that only has spell power, or take a buff that
  only raises intellect. Two readings that differ in just one stat settle the question
  immediately.
- **At low levels, undress.** Taking off all your gear outside combat, then putting it back on,
  gives it a zero-spell-power reading next to your geared one. That's the widest spread you
  can make, and the spread is what makes the numbers precise.

## The browser

Type `/ss` (or click SpellScale in the minimap's addon menu) to open a window that lists every
spell and talent with its formula, for example `87-96 Fire damage = 21-30 + 42.9% Fire SP`.
It has a search box; searching for "not taken" lists talents you haven't picked.

| Command | What it does |
|---|---|
| `/ss` | Open or close the browser |
| `/ss spell <name or id>` | Show what it currently believes about a spell, reading by reading |
| `/ss scan` | Re-read your spells and talents now |
| `/ss tooltips` | Turn tooltip annotations on or off |
| `/ss hints` | Turn the "still learning" tooltip line on or off |
| `/ss reset` | Forget everything this character has learned |

## Install

1. Download the `SpellScale-v…-forever.zip` file from the [Releases](../../releases) page. The green
   "Code → Download ZIP" button gives you the source in a differently named folder, which the
   game won't load as-is.
2. Unzip it into your Forever client's `Interface\AddOns\` folder, so you end up with
   `AddOns\SpellScale\SpellScale.toc`. On the beta that's
   `World of Warcraft\_classic_beta_\Interface\AddOns\`.
3. Restart the game.

The addon targets interface 16001 (the Forever beta). If Blizzard changes it, tick "Load out
of date AddOns" at character select until there's an update.

Learned data is saved per character, separately from the addon folder, so updating the addon
keeps it.

## Limits

- It learns what the tooltip says. If a tooltip doesn't update with your stats (as with a beta
  bug on Flametongue Weapon), the addon will report that spell as not scaling.
- Coefficients include your talents. If a talent changes a spell's numbers without changing
  your stats, that spell starts learning again.
- Nothing is read in combat, because stats are hidden from addons there.
- Number parsing assumes an English client (`1,234` and `1.5`).

## Debugging odd results

`tools/replay.lua` runs a character's saved readings back through the solver outside the game,
showing every reading, which stats moved, and what it concluded:

```
lua5.1 tools/replay.lua path/to/WTF/Account/<account>/<realm>/<character>/SavedVariables/SpellScale.lua "Seal of Command"
```

## Development

```
SpellScale/      the addon itself
  Parse.lua      pulls numbers out of tooltip text
  Solver.lua     works out which stat explains each number, and how precisely
  Core.lua       stat snapshots, reading the spellbook and talents, saved data, slash commands
  Tooltip.lua    tooltip annotations
  UI.lua         the browser window
tests/           runs the addon against a small fake WoW client
tools/replay.lua replays saved readings from a real character
```

The tests need a Lua 5.1 interpreter, the same Lua version WoW uses:

```
lua5.1 tests/test_units.lua
lua5.1 tests/test_e2e.lua
```

`test_e2e.lua` plays a session against the fake client: gear swaps, buffs, a level-up, a
talent change, combat and a talent tree. It then checks the formulas the addon learned.
`test_units.lua` covers tooltip-text parsing, readings from real play that once fooled the
solver, and 2000 random formulas with gear swaps, level-ups and talents.
GitHub runs both on every push.

To release, push a version tag (`git tag v0.3.0 && git push --tags`). A GitHub Action
packages the addon with the [BigWigs packager](https://github.com/BigWigsMods/packager) and
publishes the zip as a release.

## License

MIT; see [LICENSE](LICENSE).
