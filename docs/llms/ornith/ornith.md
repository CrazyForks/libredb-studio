# ornith

`ollama pull ornith:<size>` · sizes supported: 9b

Every size listed here runs **all six agent surfaces**, five consecutive times each: 30 of 30
runs. One size, and it clears every surface with no setting of its own beyond a single extra plan turn.

## What it does, and how long it takes

Seconds are the median of the runs that passed, per surface.

| Size | Disk | Investigate | Optimize | Assess | Operate | Analyze | Plan | Median | Slowest |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ornith:9b | 5.5 GB | 20s | 36s | 51s | 21s | 16s | 31s | **31s** | 1:58 |

Every cell is 5/5, so the table says how long rather than whether.

## What it needs that the defaults do not give it

### `ornith:9b`

**one extra plan turn.** Its plans describe the schema correctly and completely and stop one sentence short of the runnable statement the surface is scored on.


---

Method, and where these numbers stop being safe to generalise from:
[`methodology.md`](../methodology.md).
