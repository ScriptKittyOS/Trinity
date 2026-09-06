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

---

## Line 1 — the ex_tauri measurement. **No refusal. ADR-0004 is confirmed.**

Three arms, pre-registered at G1 before any was run. Toolchain: Elixir 1.20.4 on Erlang/OTP 28,
erts-16.4.0.5, from `.tool-versions`.

### Arm (c) — is `~> 27.0` a hard guard or a default? **Read first, because it decides what (a) and (b) mean.**

```
$ mix hex.package fetch ex_tauri 0.2.0 --unpack --output ./ex_tauri-0.2.0 ; echo "exit=$?"
ex_tauri v0.2.0 extracted to ./ex_tauri-0.2.0
exit=0

$ grep -rn 'otp_release' ex_tauri-0.2.0/
ex_tauri-0.2.0/mix.exs:14:      otp_release: "~> 27.0",
ex_tauri-0.2.0/lib/ex_tauri.ex:29,31,34,44
ex_tauri-0.2.0/lib/ex_tauri/task_helpers.ex:35,37,40,51
```

The guard is two branches on `:erlang.system_info(:otp_release)`, not on the `mix.exs` key:

* `major < 27` → **`Mix.raise`**. A hard refusal.
* `major > 27` → **`Mix.shell().info`**, a warning. **No raise.**
* `major == 27` → `:ok`.

**`~> 27.0` in `ex_tauri`'s `mix.exs` is declarative metadata.** Mix enforces `:elixir` as a version
requirement; it has no built-in `:otp_release` enforcement. The behaviour lives entirely in the runtime check
above, and at OTP 28 that check **warns**.

### Arm (a) — default configuration on the pinned toolchain. **Succeeds.**

```
$ mix deps.compile ; echo "exit=$?"          # the whole tree, in dependency order
exit=0

$ mix deps.compile ex_tauri ; echo "exit=$?"
exit=0

$ mix compile ; echo "exit=$?"
Compiling 5 files (.ex)
Generated trinity app
exit=0

$ ls _build/dev/lib/ex_tauri/ebin/*.beam | wc -l   → 31
$ ls _build/dev/lib/igniter/ebin/*.beam  | wc -l   → 63
$ ls _build/dev/lib/burrito/ebin/*.beam  | wc -l   → 20
```

All seven `mix ex_tauri.*` tasks are available. The guard fires exactly as arm (c) predicted:

```
$ mix run -e 'ExTauri.TaskHelpers.check_otp_version()' ; echo "exit=$?"
Warning: ExTauri targets OTP 27 but you are running OTP 28.
Burrito may not have pre-compiled ERTS for OTP 28 yet.
Development should work, but production builds may fail.
exit=0
```

**Exit 0. A warning, not a refusal.** And its stated reason is the same stale fact ADR-0005's second
correction already refutes: slice 000 measured that Burrito 1.6.0 **can** fetch OTP 28 ERTS for all four
targets and **cannot** fetch OTP 27 for macOS or Linux. The warning has it backwards.

### Arm (b) — the override. **Moot, and not performed.**

The pre-registered rule is that a refusal is (a) **and** (b) both failing. **(a) succeeded, so there is
nothing to override and no refusal to clear.** Arm (c) also shows why an override could not have helped:
the check reads `:erlang.system_info/1` at runtime, so no project-config key changes its answer.

**The configuration recorded for ADR-0004 is therefore the default**, `{:ex_tauri, "~> 0.2", only: :dev}`,
with no override.

### Two false failures, mine, recorded because the method was the defect

I reported arm (a) as failing **twice** before it was true, and both were my method rather than the subject.

**First**, I declared the dependency `only: :dev, runtime: false`. `runtime: false` is not the default, and
arm (a) is defined as the *default* configuration. It failed with
`module Igniter.Mix.Task is not loaded`.

**Second**, with the flag corrected, I ran `mix deps.compile ex_tauri` and then
`mix deps.compile igniter` in isolation, and read `Type checking failed with errors` —
`struct Sourceror.Zipper is undefined`, `struct Rewrite.Source is undefined` — as an Elixir 1.20
incompatibility in `igniter`. **It is not.** Compiling one dependency by name does not first build the
dependencies *it* needs, so the undefined structs were a build-order artifact I manufactured. `mix
deps.compile` with no arguments, which is the ordinary path, exits 0 and builds all three.

**The lesson, stated so it is not repeated:** testing a dependency in isolation can manufacture a failure
the ordinary path does not have. A negative result about a dependency is only worth reporting after the
ordinary build has been tried. Had I stopped at either point I would have filed a Question against
`ex_tauri` and ADR-0004 for a defect that does not exist, and the recommendation in it would have been
wrong.

### Outcome

**No refusal, so no stop.** ADR-0004's provisional decision to target `ex_tauri` survives its first
measurement; whether it *packages* is lines 3 to 9, and confirmation is line 12's business, not this one's.
Carrying on to line 2.

---

## Line 3 — Burrito wiring and the non-hex toolchain. Six deviations, recorded before the commit.

Dated 2026-09-06. The G1 Decision's item 3 read:

> Pin Rust in `.tool-versions` and the Tauri CLI at its measured version, add both as
> VERSIONS.md rows with their own stated derivation (`rustc --version`, `cargo tauri
> --version`), and state in NOTES.md that these rows are marked from those commands rather
> than from the lock.

Measurement contradicted three of its clauses and added a fourth pin it did not anticipate.
Everything below is a deviation from the approved plan, recorded here **before** the commit
that carries it, per CLAUDE.md §1.

### D1 — Rust is pinned in `rust-toolchain.toml`, not `.tool-versions`

`asdf` on this machine has plugins for elixir and erlang and **no rust plugin**, and asdf does
not fail on a tool it has no plugin for. Measured in a scratch directory whose `.tool-versions`
carried a `rust 1.92.0` line:

```
$ asdf current ; echo "exit=$?"
Name            Version         Source                  Installed
elixir          1.20.4-otp-28   .../.tool-versions      true
erlang          28.5.0.5        .../.tool-versions      true
exit=0

$ asdf install >/dev/null 2>&1 ; echo "asdf install exit=$?"
asdf install exit=0
```

**The rust line is absent from `asdf current` and `asdf install` exits 0.** A `rust 1.92.0`
line in `.tool-versions` would be a pin that pins nothing — the same defect class as a ✅ whose
meaning is assumed. `rustup` owns Rust here and does act on its own file:

```
$ rustup show active-toolchain ; echo "exit=$?"
1.92.0-x86_64-unknown-linux-gnu (overridden by '/home/aylac/Projects/Trinity/rust-toolchain.toml')
exit=0

$ rustc --version ; echo "exit=$?"
rustc 1.92.0 (ded5c06cf 2025-12-08)
exit=0
```

`rust-toolchain.toml` is committed and its first line says why it is not `.tool-versions`.

### D2 — the Tauri CLI's derivation command is not `cargo tauri --version`

The Decision named `cargo tauri --version`. On this machine, before and after everything:

```
$ cargo tauri --version ; echo "exit=$?"
error: no such command: `tauri`
exit=101
```

`ex_tauri` does not expect the CLI on `PATH`. It installs the CLI itself, into its own
installation path, which defaults to `_build/_tauri` and is gitignored:

```
ex_tauri-0.2.0/lib/ex_tauri/install/helpers.ex:493
  ["install", "tauri-cli", "--version", "^#{cli_version}", "--root", "."]
ex_tauri-0.2.0/lib/ex_tauri.ex:99
  def installation_path, do: ... Path.join(Path.dirname(Mix.Project.build_path()), "_tauri")
```

Run exactly as `ex_tauri` would run it:

```
$ cargo install tauri-cli --version '^2' --root _build/_tauri ; echo "exit=$?"
  Installing _build/_tauri/bin/cargo-tauri
   Installed package `tauri-cli v2.11.4` (executable `cargo-tauri`)
exit=0

$ _build/_tauri/bin/cargo-tauri tauri --version ; echo "exit=$?"
tauri-cli 2.11.4
exit=0
```

**The measured pin is 2.11.4** and the deriving command is the one above, not the Decision's.
Two consequences are stated in the row rather than left implicit: the `^2` requirement floats,
so 2.11.4 is what it resolved to on 2026-09-06 and not a lower bound anyone re-running this
will necessarily get; and because the binary lives under a gitignored path, **no file in the
tree carries this pin**. Its VERSIONS.md mark is 📐, never ✅ — see D3's second half.

### D3 — a fourth pin the Decision did not anticipate: Zig, and it must be exact

Burrito 1.6.0 does not accept a Zig range. `deps/burrito/lib/burrito.ex`:

```
@zig_version_expected %Version{major: 0, minor: 16, patch: 0}
...
if version != @zig_version_expected do
  Log.error(:build, "Your Zig version does not match the one Burrito requires! ...")
  exit(1)
end
```

Zig was absent (`zig version` → exit 127). `asdf` **does** have a zig plugin, so unlike Rust
this one belongs in `.tool-versions` and is a real pin there:

```
$ asdf plugin add zig && asdf install zig 0.16.0 ; echo "exit=$?"
exit=0

$ cat .tool-versions
erlang 28.5.0.5
elixir 1.20.4-otp-28
zig 0.16.0

$ asdf current ; echo "exit=$?"
zig             0.16.0          /home/aylac/Projects/Trinity/.tool-versions true
exit=0
```

**The mark mechanism had to change, and this is the line's red.** Before this commit,
`Mix.Tasks.Versions.Gen.mark/3` marked *every* toolchain row from a hardcoded constant:

```elixir
def mark(_row, :toolchain, _locked), do: "✅ `.tool-versions`"
```

so `VERSIONS.md` line 71 read

```
| `Rust + Tauri CLI` | stable | ✅ `.tool-versions` | ... |
```

while

```
$ grep -in 'rust\|tauri' .tool-versions ; echo "exit=$?"
exit=1
```

A ✅ naming a file that carried neither name — **finding B3's defect, living inside the
enforcer slice 000 built to prevent it.** `test/versions_toolchain_mark_test.exs` was committed
failing at `82e74a3` (3 of 5 failing, `mix test` exit 2) and is green after the fix. Every
toolchain row now states a `:from`: `{:file, path, needle}` marks ✅ only when that file
actually carries the pin and ❌ when it does not, and `{:command, cmd}` marks 📐 and can never
reach ✅, because nothing at this sha verifies it.

### D4 — the Credo check had to leave `lib/`, which is a change to slice 000's tree

The first `MIX_ENV=prod mix release` never reached anything about releases:

```
$ MIX_ENV=prod mix release desktop
    error: module Credo.Check is not loaded and could not be found
    │
 12 │   use Credo.Check,
    └─ lib/trinity/credo/no_eval_on_model_output.ex:12
exit=1
```

`credo` is `only: [:dev, :test]` and `lib/` compiles in every environment, so slice 000's own
Credo check makes the app uncompilable in `:prod`. Under §8 that red is at an earlier fault
than line 3's claim and had demonstrated nothing, so it was fixed before the real red was
taken: the check moved to `credo_checks/`, which `elixirc_paths/1` adds for `:dev` and `:test`
only. The module name, its test and `.credo.exs` are unchanged.

**This is a change outside packaging by the letter of the plan's constraint.** It is recorded
here rather than waved through. The judgement made: a tree that cannot compile under
`MIX_ENV=prod` cannot be packaged at all, so this is a packaging prerequisite rather than a
widening of scope, and it adds no domain code — it moves one file and adds two lines to
`elixirc_paths/1`. **If the owner reads it the other way, it should be lifted out of slice 001
and given to a slice of its own**, and the rest of line 3 stands without it only in the sense
that nothing after this point could have been measured.

### D5 — `burrito` is now a direct dependency, not `only: :dev`

`&Burrito.wrap/1` is a release step and runs under `MIX_ENV=prod`. `ex_tauri` is `only: :dev`
and so is the burrito it brings, so the module would not exist in the environment that calls
it. `{:burrito, "~> 1.6"}` is declared directly. Its VERSIONS.md row already existed and now
marks ✅ from the lock at 1.6.0.

### D6 — the `windows_x86_64` target cannot be built on this machine

All three targets are declared in `mix.exs`. Building all three:

```
$ MIX_ENV=prod mix release desktop --overwrite ; echo "exit=$?"
...
--> Resolving ERTS: {:precompiled, [version: "28.5.0.5"]}
--> Remote ERTS From Beam Machine: https://github.com/erlang/otp/releases/download/OTP-28.5.0.5/otp_win64_28.5.0.5.exe
** (RuntimeError) Couldn't find 7z/7zz
    (burrito 1.6.0) lib/util/default_erts_resolver.ex:80
exit=1
```

The Windows ERTS ships as a `.exe` installer and burrito unpacks it with 7z. None of
`7z 7zz 7za 7zr p7zip` is present; `apt-cache policy p7zip-full` reports `Installed: (none)`,
and installing it needs root, which CLAUDE.md §7 keeps off this agent's hands.

**This is a host prerequisite, not a code defect**, and it goes to the owner as a question and
to the manual queue rather than being fixed here. Line 3's green is therefore taken on the one
target this host can build:

```
$ BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mix release desktop --overwrite ; echo "exit=$?"
exit=0

$ stat -c '%n %s' burrito_out/* ; echo "exit=$?"
burrito_out/desktop_linux_x86_64 20697016
exit=0

$ file burrito_out/desktop_linux_x86_64
burrito_out/desktop_linux_x86_64: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped
```

**One unexpected positive, stated as measured and no further.** In the three-target run before
it failed on Windows, burrito cross-built `desktop_macos_aarch64` (13,782,104 bytes) on this
Linux host through Zig. That binary is unsigned, unnotarised and cannot be launched here, so it
proves that the macOS *cross-compile* works and **nothing about whether the macOS app runs**.
AC2 stays `[manual]` with "no machine available" unchanged.

### A method error of mine, recorded because it recurred

I measured the release twice: once piped to `tail` for the output, once redirected to
`/dev/null` for the exit code. Burrito caches ERTS between runs, so the two invocations were
not the same run, and I printed `exit=0` beside output from a run that had raised. This is the
third time in this slice that measuring a thing twice has produced a claim about neither run.
The rule I am applying from here: **one invocation, output to a file, exit code taken from that
same invocation.** Every command block above was taken that way.

Redoing it that way also surfaced something worth keeping: `mix release` with a release
directory already present prompts `Overwrite? [Yn]`, gets no stdin, and **exits 0 having built
nothing**. `--overwrite` is on every release command in this slice for that reason.

### Follow-ups this line opened

- `7z`/`7zz` is a host prerequisite for the Windows target. Needs root, so it is the owner's to
  install or the CI runner's to provide. Blocks nothing on Linux.
- The `^2` Tauri CLI requirement floats and no file in the tree pins it. If a reproducible
  desktop build matters later, that pin needs somewhere real to live.
- `mix release`'s exit-0-on-declined-overwrite is a footgun for any CI job that omits
  `--overwrite`; `.github/workflows/package.yml` at line 9 must carry it.

---

## Line 4 — `Trinity.Paths`. Green, and it opened a hole in slice 000's skip enforcer.

Dated 2026-09-06. Red committed at `ec64ac7`: the first pass resolved one root for every OS and
`PathsTest` failed 3 of 6 on it, including "the three roots are distinct for the same home",
which collapsed to `["/h/.local/share/trinity"]`. Green after the branch split, 6 of 6.

The three roots are `SLICE.md`'s. The case difference between them is deliberate and is stated
in the module: `trinity` lower-case is the XDG convention, `Trinity` capitalised is the macOS
and Windows convention.

### Two enforcer findings, both from the same three lines of code

**Sobelow flags `File.mkdir_p!(dir)`** as `Traversal.FileModule`, low confidence, because `dir`
is a variable. Every possible implementation of this function passes a variable there, so no
artifact change removes it; it is a named exception. It was taken **inline**, with
`@sobelow_skip`, rather than in `.sobelow-skips`, because that file keys on file **and line**
and slice 000 already measured what that costs — adding SPDX headers moved `router.ex:10` to
`:12` and silently reopened the finding. `paths.ex` is still being edited this slice.

**Which exposed the hole.** `SobelowSkipsTest` asserted every skip carried a reason, and it only
knew about `.sobelow-skips`. An `@sobelow_skip` attribute is a second skip mechanism it could
not see, so a reasonless inline skip passed the gate. The test now derives its population from
`git ls-files` and requires a `# sobelow_skip reason:` line above every inline skip. Demonstrated
by planting the violation and removing it, the way slice 000's five enforcers were:

```
$ mix test test/sobelow_skips_test.exs ; echo "exit=$?"     # reason comment removed
  1) test inline @sobelow_skip attributes every inline skip is immediately preceded by its reason
     these @sobelow_skip attributes carry no `# sobelow_skip reason:` line above them:
     ["lib/trinity/paths.ex:71"]
exit=2

$ mix test test/sobelow_skips_test.exs ; echo "exit=$?"     # reason restored
Result: 3 passed
exit=0
```

**The check was wrong twice before it was right, and both corrections were to the check.** First
its population was `String.contains?(line, "@sobelow_skip")`, which matched its own moduledoc
and its own assertion message — five false hits in one file. The population is now an attribute
*definition* anchored at the start of a line. Second, it demanded the reason on the single line
immediately above, and rejected a correct six-line reason for being six lines; the rule now
walks the contiguous comment block above the attribute. Neither fix was an exemption. In both
cases the check was making a claim about the tree that the tree did not owe it.

### `@sobelow_skip` does not survive `--warnings-as-errors` on its own

```
warning: module attribute @sobelow_skip was set but never used
 77 │   @sobelow_skip ["Traversal.FileModule"]
   └─ lib/trinity/paths.ex:77: Trinity.Paths (module)
Compilation failed due to warnings while using the --warnings-as-errors option
```

Sobelow reads the attribute out of the source AST and the compiler never sees it used.
`Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)` makes it a real attribute
to the compiler without changing what sobelow reads; `MIX_ENV=test mix compile
--warnings-as-errors --force` then exits 0. **Anyone adding an inline sobelow skip to this
project needs that line or the gate rejects the file**, which is why it is in `paths.ex` with
its reason next to it rather than in a commit message.

### One thing line 4 did not do

`Trinity.Paths.database_path/0` exists and nothing calls it yet. `config/runtime.exs` still
raises without `DATABASE_PATH`, which is right for a server and wrong for a double-clicked
binary. Wiring it is line 5's, with the smoke run as its red.

### A correction to line 3's D6

I wrote that the Windows 7z prerequisite was something the Decision "did not anticipate". That
is wrong about the record: `SLICE.md`'s own Risks section already says "Windows ERTS unpacking
needs 7-Zip per Burrito notes; document." **This supersedes that framing.** What line 3 added
was the measurement — the exact error, the resolver line it comes from, and that no 7z variant
is installed and installing one needs root. The risk was written down before I got there.
