# al

`ls` for AI agents, not humans.

`ls` is designed for eyes: it optimizes for scanning and color. An agent
needs different facts before it decides what to read: how large a file is,
whether it is text, how many lines it has, roughly how many tokens reading
it will cost, how old it is, and which directories are generated noise.
`al` by default prints plain names, one per line, like `ls` when piped;
`--table` puts exactly those facts in one deterministic, tab-separated table,
with JSON when a program is consuming it.

## Rules

Use git commit after changed code.

For directory listings use `al`: `al` to discover names,
`al -T -d 2` to triage a subtree, and `al -R` instead of
`ls -R` or `ls -lR`. Never run `ls -lR` / `ls -R` on a repo root.
