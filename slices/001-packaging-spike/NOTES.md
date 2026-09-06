# Slice 001 — NOTES

## G1 plan

Posted 2026-09-06 against `537bd3a`, branch cut from `main` at `de95666`. Fifteen lines, execution order, one
sentence each, each naming what it produces and the red it fails on first. **No code until this is approved.**

1. **The `ex_tauri` measurement runs before any packaging work, and all three arms are pre-registered here before any is run**: **(a)** default configuration on the pinned toolchain — `mix deps.get` then `mix deps.compile ex_tauri` with `{:ex_tauri, "~> 0.2", only: :dev}` in `mix.exs`; **(b)** the same with `otp_release` overridden to `28.5.0.5` in this project's config; **(c)** whether `~> 27.0` is a hard guard in `ex_tauri`'s own code or a default it downloads against, read from the unpacked source with `mix hex.package fetch ex_tauri 0.2.0 --unpack` and `grep -rn "otp_release\|27" <src>` — output and exit code recorded per arm, **a refusal being (a) and (b) both failing**, and if (b) works there is no refusal, ADR-0004 is confirmed and the override is recorded as the configuration.
2. **The acceptance-criteria tag review** produces a corrected `slices/001-packaging-spike/SLICE.md` and its Manual verification queue, failing first on the mistags this slice was predicted to carry: AC4 and AC5 claim `[auto]` for things needing a desktop session or a machine that does not exist, and AC6 mixes an auto half with a manual one.
3. **Burrito wiring and the non-hex toolchain** produce the `releases:` block in `mix.exs`, `lib/trinity/release.ex` running migrations explicitly, a **Rust pin in `.tool-versions`** and the **Tauri CLI pinned at its measured version**, plus their two `VERSIONS.md` rows whose marks come from `rustc --version` and `cargo tauri --version` rather than from `mix.lock` — red on `MIX_ENV=prod mix release` failing before the release assembles, and on `mix versions.gen --check` if those rows are emitted as if lock membership had answered for them.
4. **`lib/trinity/paths.ex`** resolves the per-OS data directory with `test/paths_test.exs` red first on each of the three branches returning the wrong root under a stubbed `:os.type/0`.
5. **`lib/trinity/smoke.ex` and the `--smoke` flag** boot the endpoint on `127.0.0.1:0`, print the assigned port, and exit 0, red first on a smoke run that stays alive past its own exit call.
6. **The linux x86_64 Burrito build** produces `burrito_out/trinity_linux_x86_64`, a single binary, launched and exited under `--smoke`, with `ps -eo pid,ppid,comm` captured before and after — **a leaked sidecar surviving the exit is the red**, and it is the criterion this line exists for.
7. **AC1's serving proof** captures `curl -sS -o /dev/null -w '%{http_code}'` against the port the smoke run printed, red first on a binary that starts but serves nothing.
8. **`docs/packaging.md`'s measurement table** records binary size from `stat -c %s` and cold-start-to-serving from a timed loop on linux x86_64 only, red on `plan_check` check 6 if it cites a path the tree does not have.
9. **`.github/workflows/package.yml`** adds macos-latest and windows-latest jobs that build the artifact, launch the **shell** on their real desktop sessions and exit under `--smoke`, and a ubuntu-latest job that **states which of two it is** — the shell under `xvfb-run`, or the sidecar smoked alone because the runner has no display — red first on a job reporting success with no artifact in its upload step, and on any runner claim that does not say which of those two it made.
10. **What a runner proves and what it cannot** is written into `docs/packaging.md` as two explicit lists — it proves the artifact builds, launches and exits clean, and it produces a launch log; it cannot produce a screenshot of a real window on a real desktop, and nothing will claim it did.
11. **Every criterion needing a real desktop is tagged `[manual]` with "no machine available — Ubuntu is the only machine" as its stated reason**, never silently dropped, and the slice's exit condition names them as unproven rather than counting them.
12. **ADR-0004 is confirmed or amended** from what lines 1 to 9 measured, as an **appended correction that names what it supersedes** and carries a status word from the vocabulary `docs/03` allows — `accepted`, since this slice is what its current `proposed → to be confirmed by Slice 001` was waiting on — with **the alternatives table kept either way**, because the next person to hit R1 needs it; red on `plan_check` check 6 if the amendment cites an alternative with no ADR of its own.
13. **`coverage.tsv` gains slice 001's row** and the drop rule does real work for the first time, red first by seeding a row more than three points under 000's **27.01** and watching `mix trinity.coverage` fail, then green at the real figure or with a reason named here.
14. **`mix gate` and `scripts/plan_check.sh` both exit 0 on this branch**, with `mix phx.server` still starting without Tauri, red on either gate or on the plain server needing the desktop shell to boot.
15. **The manual queue holds only what the tree cannot answer**, each item naming the machine or account it needs: a macOS desktop for AC2, a Windows desktop for AC3, a Linux desktop session for AC4's window, and the same three for AC6's window-close check — **all four are the same missing thing, a machine that is not this one.**

## Constraints this plan is written under

**Nothing here adds domain code.** `Trinity.Release`, `Trinity.Paths` and `Trinity.Smoke` are named in this
slice's own Deliverables and exist only to make a binary boot and stop. If the spike turns out to need a change
outside packaging, that is a Question on the slice issue, not a commit.

**The pin does not move.** ADR-0005's second correction settled OTP 28.5.0.5 on a measurement of Burrito's artifact
index. If `ex_tauri` refuses it, that is ADR-0004's decision to make under its alternatives, which is what line 1
routes to.

## Two VERSIONS.md rows the generator's rule does not cover

Packaging brings a **Rust toolchain** and the **Tauri CLI** into the tree. Neither is a hex package, so the
`✅ in mix.lock` derivation slice 000 built **cannot mark them** — lock membership has nothing to say about either.

Their rows carry their own stated derivation instead: `rustc --version` and `cargo tauri --version`, named in the
row the way the toolchain rows name `.tool-versions`. Without that, the generator's rule reads as if it covered
the whole table, which would be the same defect finding B3 caught — a mark whose meaning is assumed rather than
stated.

## The tag review, done now rather than at G3

`SLICE.md` carries seven criteria. Three are tagged `[manual]` and four `[auto]`. **Three of the four `[auto]`
tags are wrong**, which is what finding I3 predicted for exactly this slice.

| AC | Tagged | Should be | Why |
|---|---|---|---|
| 1 | `[auto]` | `[auto]` | Correct. A binary on this machine, curl against the port it prints. |
| 2 | `[manual]` | `[manual]` | Correct. Needs a **macOS desktop**. |
| 3 | `[manual]` | `[manual]` | Correct. Needs a **Windows desktop**. |
| 4 | `[auto]` | **`[manual]`** | "Linux: same" means a native window showing the scaffold. A window on a desktop session is not a command's output. The clause "or documented not tested — no machine" is a waiver, not an automation. |
| 5 | `[auto]` | **split** | Binary size and cold-start are `[auto]` **on linux x86_64 only**. "Per OS" cannot be measured for macOS or Windows without those machines, and "first paint" needs a window on any of them. |
| 6 | `[manual]` | **split** | Killing a *window* is `[manual]`. But the property underneath — no leaked sidecar after the process exits — is `[auto]` under `--smoke` with `ps` before and after, and line 6 proves it on linux today. |
| 7 | `[auto]` | `[auto]` | Correct. Two commands. |

Applying this is line 2, in a commit of its own, so the retag is reviewable apart from the packaging work.

## Manual verification queue — four items, one missing thing

Every one needs a machine that is not this one. **The owner's only machine is Ubuntu.**

| Item | Needs | Criterion |
|---|---|---|
| Native window on macOS, screenshot | a **macOS desktop** | AC2 |
| Native window on Windows, screenshot, or the documented fallback | a **Windows desktop** | AC3 |
| Native window on Linux, screenshot | a **Linux desktop session** (this machine has no display in use here) | AC4 after retag |
| Window close terminates the sidecar within 5 s | any one of the three desktops | AC6's manual half |

A GitHub Actions runner covers none of these: it can build the artifact, run it under `--smoke`, and keep the
launch log, and that is what lines 9 and 10 claim and no more. **No screenshot of a real window on a real desktop
exists for macOS, Windows or Linux, and the slice will exit saying so rather than counting those criteria as met.**
