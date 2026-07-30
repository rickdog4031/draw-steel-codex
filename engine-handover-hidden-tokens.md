# Engine handover: sync hidden tokens to player clients in a concealed form

**From:** Ricky (Draw Steel hide/Hidden-condition revamp, mod layer)
**To:** engine team, for review
**Date:** 2026-07-24

## Summary of the ask

Change the engine so that tokens flagged `invisibleToPlayers` are still synced to
player clients -- present in game state and in the Lua API surface -- but fully
concealed: not rendered, not interactable, and absent from every player-facing
UI surface. Today the engine withholds these tokens from player clients
entirely, and that makes one part of the Draw Steel hiding rules impossible to
implement in the mod layer.

## Context: the hide revamp (mod layer, already working)

We are implementing the Draw Steel hiding rules in the codex:

1. **Hide maneuver UX** - when a creature attempts to hide, sight arrows are
   drawn to every enemy labeled with cover/concealment/blocked vision, plus an
   adjudication prompt. Shipped, works.
2. **Hidden monsters vanish for players** - while a director-controlled
   creature has the Hidden condition (and a Rules Enforcement toggle is on),
   the director's client sets `invisibleToPlayers` on its token. Shipped,
   works.
3. **Targeting enforcement** - RAW: "While you are hidden from another
   creature, the creature can't target you with abilities that don't have the
   Area keyword." Non-Area targeting is blocked in the mod layer
   (`GameSystem.AllowTargeting`). Shipped, works.
4. **Area abilities must still hit hidden creatures** - RAW: an Area ability
   cast over the hidden creature's square DOES affect them (with no targeting
   UI revealing they are there). **This is the broken part**, and only for
   player-cast areas against hidden monsters.

## The blocker, with evidence

Area target collection runs on the casting client in Lua
(`dmhub.tokenInfo.TokensInShape`, plus a fallback sweep of `dmhub.allTokens`
we added). We instrumented the sweep and had a player client hover an area
cube over a hidden monster's square:

```
HIDEDEBUG:: isDM=false allTokens=4 sweep=[Goblin Warrior 2] invisible=[]
```

The director's client has 5 tokens on this map; the player client's
`dmhub.allTokens` has 4. The `invisibleToPlayers` token is not merely
unrendered on player clients -- **it does not exist in their game state at
all**. No `invisibleToPlayers` flag to read, no `locsOccupying`, nothing.
Therefore the caster's client cannot include the hidden monster in the cast's
target list, and no client-side Lua can fix that.

Note the asymmetry: hidden *heroes* keep visible tokens by design (their
enemies are director-run, and the director must see everything), so
monster-cast areas against hidden heroes already resolve correctly. The gap is
exclusively player-cast areas vs hidden monsters.

## Approaches we tried and rejected in the mod layer

- **Client-side sweep augmentation**: merge `invisibleToPlayers` tokens from
  `dmhub.allTokens` into the area sweep. Works on the director's client; dead
  on player clients because the tokens are stripped (above). The code is in
  `DrawSteelActionBar.lua` and is dormant-but-correct: it lights up
  automatically the moment hidden tokens exist client-side.
- **Director adjudication prompt**: the casting client broadcasts the covered
  squares; the director's client matches them against hidden monsters and pops
  a modal asking the director to apply effects manually. Implemented,
  functional, and reverted: interrupting the director with a modal and making
  them hand-resolve damage/slides for every player area cast is a poor play
  experience.

## Requested engine behavior ("concealed sync")

Sync `invisibleToPlayers` tokens to player clients with a per-client
*concealed* state:

- **Present in game state / Lua**: the token appears in `dmhub.allTokens` (and
  `allTokensIncludingObjects`), with `properties`, `locsOccupying`,
  `invisibleToPlayers = true` readable. This is what lets area target
  collection and damage/effect application work on the casting client.
- **Not rendered**: no token art, nameplate, stamina bar, status icons, or
  floating text. (Floating damage text after an area hit WILL reveal position
  via the resulting property change -- that is accepted and desired; the
  reveal comes from the damage, not from the concealed token's own UI.)
- **Not interactable**: cannot be clicked, hovered, right-clicked, or box-
  selected; no tooltip; not focusable. Ideally excluded from
  `dmhub.tokenInfo` / `SheetHud` (no sheet), which automatically keeps every
  sheet-based UI affordance (target rings, hover highlights) from leaking.
- **Not blocking for player interaction where it would leak**: today players
  can path through / land on the hidden monster's square precisely because the
  token does not exist for them. If concealed tokens participate in collision
  or square-occupancy checks on player clients, walking into the square
  becomes a wallhack-style detector. Either keep concealed tokens
  non-blocking for player movement, or accept/design that leak deliberately
  (RAW tables usually rule you cannot end movement in an occupied square, so
  there is a legitimate design question here -- flagging it rather than
  prescribing).
- **Vision/fog unchanged**: the concealed creature's own vision contribution
  (if any) should not be revealed to players.

### Known leak surfaces to audit (mod layer will help)

- Any Lua that iterates `dmhub.allTokens` and surfaces counts or names to
  players (encounter widgets, "all enemies" symbol evaluation, initiative).
  Initiative rows for director monsters already exist while hidden, so this
  is mostly about not ADDING new leaks.
- Power roll dialogs / action log naming a concealed token swept by an area.
  Position reveal via damage is accepted; whether the NAME should be masked is
  an open product question, solvable in the mod layer once the engine change
  lands.
- Console access: a technical player could inspect concealed tokens via the
  Lua console. Same trust model as other client-synced-but-hidden data; worth
  an explicit sign-off.

## Why this design and not alternatives

- **Keep stripping + engine-side cast injection** (the director's or server's
  authority injects hidden targets into a player's cast): crosses the
  client-authority boundary mid-cast, much larger change, and still needs the
  concealed data somewhere to resolve effects (damage formulas run on the
  casting client).
- **Keep stripping + prompt**: tried; poor UX (above).
- **Concealed sync** keeps the existing client-authoritative cast flow: the
  caster's client simply knows about one more token it is not allowed to show.
  All the Draw Steel rules code for this feature is already written and tested
  against the director's client, where tokens are never stripped -- it needs
  no changes to benefit.

## Nice-to-have (separate, small)

When `invisibleToPlayers` flips, player clients currently pop/cut the token.
A short alpha fade on the transition (~0.5s, ideally after a ~2s hold that the
mod layer already provides on the hide side) would make hiding/revealing read
much better. Mod layer cannot animate token art alpha.

## How to verify (playground game)

Game `MysteriousRelentlessTrustworthyMonarch` (Inn of Beginnings map): Polder
Shadow (player-controlled by test account Rickaboy) vs Goblin Warriors.

1. As director: enable Settings > Game > Rules Enforcement > "Hidden Monsters
   Invisible to Players"; give Goblin Warrior 1 the Hidden condition (or have
   it use the Hide maneuver). Token vanishes on the player client.
2. As the player: confirm the goblin is not in `dmhub.allTokens` today; after
   the engine change it should be present with `invisibleToPlayers = true`
   but produce no rendering or interaction.
3. As the player: cast any Area-keyword ability (e.g. a cube) over the
   goblin's square. After the engine change, the existing mod code should
   include it in the cast, apply damage, and show no targeting ring during
   placement. Damage floats revealing the position afterward is intended.
4. Regression: free strikes / non-Area abilities still cannot target the
   hidden creature from either side; allies still can; director-cast areas
   still hit it.

## Mod-layer contacts / code pointers

- `Draw Steel Core Rules/MCDMRules.lua` - `GameSystem.AllowTargeting` hidden
  rule (non-Area blocking).
- `Draw Steel Core Rules/MCDMCreature.lua` - `SyncHiddenInvisibility` (sets
  `invisibleToPlayers` from the Hidden condition, director client only;
  `strict:hiddeninvisible` game setting).
- `DrawSteelActionBar/DrawSteelActionBar.lua` - area sweep augmentation that
  merges `invisibleToPlayers` tokens from `dmhub.allTokens` into
  `TokensInShape` results (currently a no-op on player clients; becomes the
  live path after this change).
