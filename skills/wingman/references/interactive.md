# Interactive debugging

Use `wingman answer` for normal questions and approvals. Use `surface` and `event` for unsupported cards or custom actions.

```bash
wingman surface --pane ID              # active card, retry fault, or pane state
wingman surface --pane ID --json       # structured response
wingman surface --pane ID --root NODE  # one subtree
wingman surface --pane ID --all --json # bounded whole surface, including scrollback
```

Read node IDs and actions from the current surface. IDs change between cards. For a manual pick and submit:

```bash
wingman event --pane ID \
  '{"ev":"action","id":"<card_id>","act":"pick:0:0"}' \
  '{"ev":"action","id":"<submit_id>","act":"submit"}'
```

Events stop at the first failure. Earlier sends cannot be undone, and Tern does not acknowledge delivery. Use `--no-rearm` on intermediate steps and re-read the surface after opening a field or editor. Text `edit` offsets and lengths are UTF-16 code units.
