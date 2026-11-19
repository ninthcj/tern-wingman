# Wingman Interactive TSP Recipes (`waiting_input`)

Use these recipes when a bound `omp` worker triggers `[Wingman waiting_input · pane <id>]` and needs more than a simple option pick.

> Pass `--no-rearm` on intermediate events and omit it on the final `submit` event so auto-callback re-arms once for the resumed turn.

## 1. Inspect the active card

```bash
wingman surface --pane <id>             # auto-scoped readable tree with node IDs and [click=...] actions
wingman surface --pane <id> --json      # full structured TSP table
wingman surface --pane <id> --all       # full pane surface instead of auto-scoped card
```

## 2. Pick option(s) and submit

`pick:<fieldIdx>:<optIdx>` works even on folded fields and toggles checkboxes:

```bash
wingman event --pane <id> \
  '{"ev":"action","id":"ui","act":"pick:0:0"}' \
  '{"ev":"action","id":"ui.actions/submit","act":"submit"}'
```

## 3. Fill free-text `Other…` (or text `<input>` / `<textarea>`)

Open the field, select `other`, inspect `<input_id>` via `surface`, then send `edit` (UTF-16 offsets/lengths) and `submit`:

```bash
wingman event --pane <id> --no-rearm '{"ev":"action","id":"ui","act":"open:1"}'
wingman event --pane <id> --no-rearm '{"ev":"select","id":"ui.body/g1/q1/f1","item":"other"}'
wingman surface --pane <id>
wingman event --pane <id> \
  '{"ev":"edit","id":"<input_id>","from":0,"to":0,"text":"Custom answer","cursor":13,"len":0}' \
  '{"ev":"action","id":"ui.actions/submit","act":"submit"}'
```

## 4. Attach an option `Note`

Open the field, trigger `act:"note"` on the option node, inspect `<editor_id>` via `surface`, then `edit` and `save-note`:

```bash
wingman event --pane <id> --no-rearm '{"ev":"action","id":"ui.body/g0/q0/f0/o0","act":"note"}'
wingman surface --pane <id>
wingman event --pane <id> --no-rearm \
  '{"ev":"edit","id":"<editor_id>","from":0,"to":0,"text":"Extra constraint","cursor":16,"len":0}' \
  '{"ev":"action","id":"ui.actions/save-note","act":"save-note"}'
```
