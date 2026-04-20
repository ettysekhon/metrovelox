# Polaris Console overlay

Files in this tree are copied on top of the pinned upstream submodule
(`apps/polaris-console/upstream/console/`) by
`scripts/build-polaris-console.sh` immediately before `docker buildx build`
and reverted via `git checkout -- <path>` in the script's cleanup trap.

This lets us keep the submodule pinned to a clean upstream commit while
carrying small, surgical customisations needed for metrovelox.

## Layout

The tree under `overlay/` mirrors the tree under
`upstream/console/`; each file here overwrites the file at the same
relative path.

```
overlay/src/lib/utils.ts  ->  upstream/console/src/lib/utils.ts
```

## Current overlays

| File                          | Why                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/lib/utils.ts`            | Prefer nested `polaris.principal_name` claim (Keycloak protocol mapper) over `sub` when resolving the current Polaris principal from the JWT access token. |

## Adding a new overlay

1. Copy the upstream file to the equivalent path under `overlay/`.
2. Edit the overlay copy — keep diffs minimal and comment the intent.
3. Add a row to the table above.
4. Rebuild with `scripts/build-polaris-console.sh --latest`.

## Upstreaming

When upstream accepts an equivalent change (or its behaviour converges),
delete the overlay file and bump the submodule commit.
