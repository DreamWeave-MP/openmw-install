# OpenMW context benchmarks

`bench/bench.jsl` times the package through its public API over an install it writes: 98 data
folders (one of 240 top-level files, 96 the shape of a mod's, the engine's own), 128 content
files spelled in three cases, and 326 loose assets below the top level. It opens a context, reads
its properties, resolves content files by name with the folders listed already and afresh, lists
content, resolves and reads loose assets, and checks activations against the folders. Each
workload is warmed up, sized to a batch of about a tenth of a second, and reported as the median
of seven batches, with a full collection between them. Every result is compared with what the
writer of the install says it must be.

`bench/cold.jsl` times what one process pays once: the `require` of this package's module with
the modules it stands on loaded first, then the first context, its first content list and one
activation over 24 folders. Each line is a single sample, so it is run many times and the medians
are compared.

```sh
jess run --package jpk/openmw --package-path jpk \
  --capability filesystem.read --capability filesystem.write \
  jpk/openmw/bench/bench.jsl <scratch folder> [filter]

jess run --package jpk/openmw --package-path jpk \
  --capability filesystem.read --capability filesystem.write \
  jpk/openmw/bench/cold.jsl <scratch folder>
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides, and the same sibling packages.
- Base: `c9f7db4`, the package before the move, with both benches. Head: the source of
  `c15fea1`, which no later commit changes.
- Protocol: the whole of `bench.jsl` against base, then head, five times over, back to back
  under one lock; each cell is the median of its five runs. `cold.jsl` the same way, forty-one
  times over. A difference under 5 percent is called no change.

| Workload | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| new: a configuration of 98 data folders and 128 content files | 232.7 | 242.2 | no change |
| fromConfig: a context over a loaded configuration | 0.398 | 0.412 | no change |
| properties: the six, read once each | 31.8 | 32.5 | no change |
| resolve: 256 content file names, the folders listed already | 72.5 | 53.5 | 1.36x |
| resolve: one name, listing 98 folders of 556 files afresh | 4657.2 | 4633.4 | no change |
| content: 128 files, the folders listed already | 50.3 | 31.1 | 1.61x |
| content: 128 files, listing 98 folders afresh | 4710.0 | 4636.7 | no change |
| resolve: 326 loose assets below the top level, the VFS built already | 234.2 | 207.2 | 1.13x |
| readFile: 326 loose assets, the VFS built already | 5616.0 | 5324.6 | no change |
| vfs: 98 folders, no archive | 5338.6 | 5265.7 | no change |
| activate: refuses a name none of 98 folders holds | 1059.4 | 957.6 | 1.11x |
| activateAll: checks 33 names and refuses the last | 20339.0 | 1493.7 | 13.62x |
| activateAll and deactivate: 32 plugins | 20483.7 | 2221.0 | 9.22x |
| activate and deactivate: a plugin in the last folder | 1093.6 | 993.5 | 1.10x |
| activate: a name already active | 17.4 | 17.4 | no change |
| deactivate: a name not active | 16.8 | 4.7 | 3.57x |

| One cold process | Base, µs | Head, µs | Base / head |
|---|---:|---:|---:|
| require @openmw-config, its two modules and @vfs | 145660.7 | 145988.2 | no change |
| require @openmw, those loaded | 2936.2 | 3220.8 | 0.91x |
| first new, 24 data folders and 24 content files | 124.1 | 126.3 | no change |
| first content, listing the 24 folders | 911.3 | 914.9 | no change |
| first activate, a plugin in the last folder | 237.0 | 230.9 | no change |
| require @openmw-install to the activation | 4205.5 | 4519.0 | 0.93x |

The cold table is a second run of the protocol. The first agreed with it on every row but the
activation, which it had at 1.07x (261.3 against 245.2); two more runs of forty-one put it at
235.9 against 228.7 and 227.6 against 223.5.

### What moved, and why

None of the gain is the dialect's. The package is a thin layer over the configuration, the
filesystem and the VFS, and what it spent of its own was three things. `resolve` asked a pattern
class (`[/\\]`) whether a path had a separator, 225 ns for a name of 22 bytes; two plain searches
answer in 50, which is the `resolve` rows and most of `content`. `content` looked its context's state up once
for every file, through the method; it now looks it up once. Activation listed every data folder
again for every name of a batch, and lowered the name once for every file of every folder: a
batch now lists a folder once, when a name first reaches it, the name is lowered once, and a file
of another length is never lowered at all. `deactivate` lowered the name once for every content
file. The batch rows (13.6x, 9.2x) are the listing; the single-name rows (1.1x) are the lowering.

What did not move is where the time is. A context that lists its folders afresh (the first
`content` or `resolve` of a process) spends 3.8 ms here: 0.86 ms listing 98 folders and 2.3 ms in
762 `fs.stat` calls, one for every top-level entry. That is the filesystem's, and nothing exact
takes it away (below).

The cold process is the other side: the module takes 0.28 ms longer to `require` (0.91x), and a
process that requires it, opens a context, lists content, activates one plugin and exits is 0.3 ms
slower (0.93x). Its one activation, over 24 folders, gains nothing that shows. A module here costs
about 12 µs a line to load, so every change for speed is also a few lines of load. Next to the
146 ms the modules below it take to load, it is 0.2 percent of the process.

### A change at a time

Each commit against the one before it, on the rows it touches: three runs warm and forty-one
cold, alternating, medians.

| Commit | What it does | Row | Before, µs | After, µs | Before / after |
|---|---|---|---:|---:|---:|
| `cd968d8` | the content list as a comprehension | content, listed already | 50.4 | 51.3 | no change |
| | | require @openmw-install | 2944.6 | 3078.9 | no change (0.96x) |
| `4bf3d6a` | two plain searches for a separator | resolve, 256 names | 76.5 | 51.3 | 1.49x |
| | | content, listed already | 51.3 | 38.5 | 1.33x |
| | | resolve, 326 loose assets | 233.5 | 217.2 | 1.08x |
| `b0e56b9` | one state lookup for a content list | content, listed already | 38.5 | 31.2 | 1.24x |
| | | resolve, 256 names | 51.3 | 54.8 | 0.94x |
| `064d7ab` | the name lowered once, lengths first | activate, refused | 933.2 | 847.1 | 1.10x |
| | | activateAll, 33 names | 18155.6 | 16212.3 | 1.12x |
| `a6dba81` | a folder listed once for a batch | activateAll, 33 names | 16212.3 | 1364.9 | 11.88x |
| | | activateAll and deactivate, 32 | 16791.7 | 2527.9 | 6.64x |
| | | require @openmw-install | 3099.2 | 3178.9 | no change (0.97x) |
| `c15fea1` | the name lowered once to deactivate | deactivate, not active | 17.1 | 4.8 | 3.59x |
| | | activateAll and deactivate, 32 | 2527.9 | 2104.7 | 1.20x |

`b0e56b9` is a trade. `resolve` now calls the function it shares with `content`, which costs it
about 14 ns a call (0.94x here, 0.97x and 0.93x in two more runs of five and seven), and saves
`content` 53 ns a file. A caller that lists content once and resolves fewer than four names for
every content file comes out ahead.

### The dialect, and what it costs to load

The payload has one dialect construct, the comprehension that builds the content list. It moves
nothing warm, and costs about 0.1 ms of `require` (0.08, 0.15 and 0.13 ms in three runs of
forty-one). The activation check is the other loop the dialect expresses exactly, as `any` over
two generators, and it stays a loop because of what it costs to load. An earlier shape of the same
changes (the folder listing in a function of its own), with its dialect constructs put back to
loops one at a time, in two runs of forty-one cold processes each, `require @openmw-install`:

| Run | Payload | µs | Against no dialect |
|---|---|---:|---:|
| first | no dialect construct | 3184.6 | |
| | the comprehension alone | 3266.2 | no change (0.98x) |
| | `any` over `enumerate` and a second generator, alone | 3537.3 | 0.90x |
| | the comprehension and that `any` | 3666.3 | 0.87x |
| second | no dialect construct | 3178.9 | |
| | `any` over one generator, inside a loop over the folders, alone | 3336.2 | 0.95x |
| | `any` over `enumerate` and a second generator, alone | 3584.3 | 0.89x |

Warm, that `any` measured the same as its loop (activate, refused: 984.4 µs before, 969.2 after;
activateAll, 33 names: 18764.1 before, 18936.0 after).

### Measured and left alone

- **`fs.walk` for the top level.** One walk a folder deep instead of a listing and a stat for
  every entry: 158 µs against 702 for a folder of 252 entries, 15.0 against 18.2 for a folder the
  shape of a mod's (three files, two folders). It is not the same check. A walk takes an entry's
  kind from the directory, so a folder that can be listed and not searched would stop raising,
  and it opens every folder below the one it walks. Not taken.
- **An intern pool for top-level names.** `pool:find` and an array read is 42 ns a name against
  77 for `string.lower` and a string key, of the 210 ns a `resolve` takes. It needs
  `string.lower` to fold exactly the letters the pool does, which is the C locale's doing and not
  this package's, and it changes what a path that is not a string does. Not taken.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-14 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.45 and 1.16 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@openmw-install`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@openmw-install` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.122 s | 0.116 s |
| Final | 0.114 s | 0.116 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| new: a configuration of 98 data folders and 128 content files | 0.2526 | 0.975× | 0.2477 | 0.981× |
| fromConfig: a context over a loaded configuration | 0.00048 | 1.025× | 0.00048 | 0.996× |
| properties: the six, read once each | 0.03853 | 0.975× | 0.03668 | 0.952× |
| resolve: 256 content file names, the folders listed already | 0.07592 | **1.351×** | 0.07511 | 0.989× |
| resolve: one name, listing 98 folders of 556 files afresh | 4.119 | 0.992× | 4.025 | 0.977× |
| content: 128 files, the folders listed already | 0.03419 | **1.504×** | 0.03240 | 0.948× |
| content: 128 files, listing 98 folders afresh | 4.066 | 1.034× | 4.032 | 0.992× |
| resolve: 326 loose assets below the top level, the VFS built already | 0.2520 | **1.080×** | 0.2492 | 0.989× |
| readFile: 326 loose assets, the VFS built already | 5.182 | 1.033× | 5.305 | 1.024× |
| vfs: 98 folders, no archive | 5.343 | 1.002× | 4.998 | 0.935× |
| activate: refuses a name none of 98 folders holds | 0.9105 | **1.091×** | 0.9029 | 0.992× |
| activateAll: checks 33 names and refuses the last | 1.442 | **1.211×** | 1.427 | 0.989× |
| activateAll and deactivate: 32 plugins | 2.252 | **1.142×** | 2.199 | 0.977× |
| activate and deactivate: a plugin in the last folder | 0.9720 | 1.032× | 0.9470 | 0.974× |
| activate: a name already active | 0.01894 | **1.182×** | 0.01876 | 0.991× |
| deactivate: a name not active | 0.00545 | **1.295×** | 0.00516 | 0.947× |

What carries the directive: `init`, whole, the package's only module. Unmarked, requiring
`@openmw-install` cost 0.005 s less than all marked (0.116 s against 0.122 s), and eight rows ran slower,
1.08x to 1.50x: resolving and listing content (`inDataDirectories`, `locate`), and activating and
deactivating (`Methods.activateAll`, `Methods.deactivate`). At 8.9 KB, compiling it costs less
than one content resolution saves, so it stays marked, and no row is more than 5% slower than all
marked.
