# Real swipe traces (M4-04)

Drop owner-consented `*.jsonl` recordings here (format: `SwipeTrace` / `SwipeTraceFile` in
`Sources/IBoardEngine/Swipe/SwipeTrace.swift`). `SwipeTraceTests.realTracesReplay` scores every file against the real
English + Hinglish lexicons and prints top-1 / top-3. Traces contain typed text: commit only data the person who typed it
agreed to publish, under a licence recorded in `LICENSE.md` next to the files. See LICENSE.md.
