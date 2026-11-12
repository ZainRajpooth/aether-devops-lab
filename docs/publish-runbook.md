
## Union blocklist (EX53e)
- Raw scan runs on UNFILTERED staging; blocklist = union(existing, TRUE/OTHER files); never replace
- Monotonic guard: shrink => halt; TRUE material (TLS keys, zitadel config) must always be excluded
- Control-bearing codemods self-exclude (hex fixture is a real finding); accepted under union
- Re-scan with proven allowlist must be 0 before push
