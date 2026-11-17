# Buff Checker (WoW Forever)

**A small bar of clickable icons for the buffs you are missing.**

Buff Checker is a World of Warcraft addon for the Forever client. It shows action-button style icons for buffs that are missing or about to run out, and nothing when everything is fine. A click on an icon casts the spell or uses the item that puts the buff back.

---

**Project status:** Early version, before 0.1. It is used daily by the author and a few guild mates. Saved settings may change format between versions.

**Transparency:** Buff Checker is written entirely by AI. All of the code and this documentation were produced by an AI coding assistant (Claude); the maintainer is not a programmer and did not write any of it by hand. His part was deciding what the addon should do, testing every change in the game and reporting what was wrong. The code is one Lua file, kept readable and commented so that it can be inspected directly.

**License:** [MIT](LICENSE)

---

## What it does

- Shows an icon for every watched buff that is missing (grey with a red tint) or has less than 2 minutes left (with a countdown, like the game's own buffs).
- Lets you click the icon to fix it. Every buff has four click slots: left click, right click, Shift + left click and Shift + right click. Each takes a spell from the spellbook or an item from the bags.
- Casts spells on yourself, always.
- Watches temporary weapon enchants (oils, stones) as well as buffs.
- Keeps a separate list for every character. Any character can be set up from any other one.
- Can keep an icon on the bar all the time ("always"): red while the buff is missing, in colour while it is on. Useful for "one of two" buffs such as Mage Armor / Ice Armor.
- Shows short buffs (2 minutes or less) with a clock sweep on the icon.
- Looks like the game's own action bars, with an optional window frame around the icons.

## What it is not

- Not a raid buff tracker. It looks only at your own character.
- Not an automation tool. Nothing is cast without your click.

## Install

1. Download this repository.
2. Copy the folder `BuffChecker` into `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game, or type `/reload`.

Your settings are stored by the game in `WTF/Account/<account>/SavedVariables/BuffChecker.lua`, not in the addon folder.

## Use

Type `/bc` to open the settings window.

- **Add this char** puts the character you are on into the list. A new character starts with a small default list for its class.
- **Active buffs** lists the buffs you have right now. Pick one and press **Add**. A buff can also be added by its spell ID on the last line of the list.
- **The checkbox** at the start of a line says whether that buff is watched.
- **The icon** at the start of a line is a slot: drop a spell or an item on it to use its icon on the bar. Empty means the buff's own icon.
- **L, R, S+L, S+R** are the click slots. Drop a spell or an item on one; right click empties it. An empty slot does nothing.
- **always** keeps the icon on the bar.
- **The arrows** change the order of the icons.
- **Save user / Restore user** store and bring back the whole list of the chosen character.
- **Show all** shows every icon so the bar can be placed. Move the bar with Alt + drag.
- **Frame** turns the window frame around the icons on and off. Its X hides the bar until `/bc` is opened again.

## In combat

The game hides buffs from addons in combat and in boss encounters, and it does not let addons show, hide or move clickable buttons there. Buff Checker works around this as far as the game allows:

- It goes by the clock: a buff seen before combat runs out when its time is up.
- It notices your own casts: casting a watched buff resets its timer.
- It reads the real state again when combat ends.

A buff that is removed early in combat (dispelled, clicked off) is therefore not noticed until combat ends.

## Requirements

- World of Warcraft, Forever client (interface 16001).
- No other addons or libraries.
