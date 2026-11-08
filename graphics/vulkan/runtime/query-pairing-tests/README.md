# query-pairing-tests

Offline, controlled Vulkan API regression for render-pass/query pairing. It
compiles the real `Ryujinx.Graphics.Vulkan` sources plus the fixture into one
assembly, injects a recording `INativeContext` (`Dispatch.cs`), and drives real
`PipelineFull` / `BufferedQuery` objects. No `VkDevice`, GPU or kernel state is
created.

`Dispatch` models the VUID semantics the Khronos validation layers reported on
device (07004/07007 family):

- `CmdBeginQuery` / `CmdEndQuery` must sit on the same side of a render-pass
  boundary; a query still open at `CmdEndRenderPass` is a dangling-violation.
- Occlusion-pool `CmdBeginQuery` outside an active subpass is a violation.
- `CmdResetQueryPool` and `CmdCopyQueryPoolResults` inside a render pass are
  violations.

Cases:

- `basic-pair` — reset outside, begin inside, end inside: the sane baseline.
- `reset-midpass` — `Begin` needing a reset while a render pass is active must
  not record an out-of-subpass `CmdBeginQuery`.
- `rpend-active` — `EndRenderPass` with an open query must close it inside the
  subpass first, not leave it dangling.
- `defer-end` — `End` before any subpass owns the begin must still produce an
  adjacent begin/end pair inside the next subpass 0.
- `two-segment-sum` — a query spanning two render passes must accumulate both
  segment results into one guest-visible result.
- `bounded-await` — `AwaitResult` with no wake signal must terminate instead of
  spinning on the sentinel forever.

Run:

```
python3 run.py --dotnet <path-to-dotnet> --deps <deps dir> --out <empty dir>
```

Output goes under `--out` only: frozen inputs with SHA-256 manifests, the
built assembly hash, per-case results and the recorded command stream in
`results.json`. Semantic failures keep a non-zero exit; a real-source build
failure is reported as infrastructure error, not as a case failure.
