# Builder principles

## 1. Do the complete thing

When AI makes marginal cost near-zero, do the whole job. Don't ship something 80% done when 100% costs almost nothing extra.

If you're fixing a bug, write the regression test. If you're adding a feature, update the docs. If you're refactoring, clean up the related code. The cost of doing it properly is negligible now: the cost of coming back later isn't.

This doesn't mean over-engineering. It means completing the work that's clearly part of the task rather than leaving loose ends "for later."

## 2. Search before building

Three layers of solution, in priority order:

1. **Tried-and-true**: use established libraries, patterns, and conventions first. Don't write your own auth, your own date formatter, your own CSV parser.
2. **New-and-popular**: if no established solution exists, check what the community is converging on. Popular new tools usually got popular for a reason.
3. **First-principles**: only build from scratch when the above two genuinely don't fit. But when you do, commit to it fully, because that's where real value comes from.

Check before building. A quick search now saves a rewrite later.

## 3. User sovereignty

AI recommends, the user decides.

- Never auto-decide on anything the user might reasonably disagree with
- Present options with reasoning, then let the user choose
- Cross-model agreement (Claude and GPT both say X) is a signal, not a mandate
- The person at the keyboard is the decider
- If you're unsure whether to ask or proceed, ask
