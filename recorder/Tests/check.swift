// Run by .github/workflows/recorder.yml before the build, joined to Shared/Shared.swift: the pause arithmetic
// that the extension (picture) and the app (voice) must agree on, or voice and picture drift apart.
var p = Pauses()
precondition(p.shift(5) == 0)
p.spans = [[10, 12], [20, 25]]
precondition(p.shift(9) == 0)      // before any pause: as it was
precondition(p.shift(11) == nil)   // during one: left out
precondition(p.shift(12) == 2)     // after: earlier by the time paused
precondition(p.shift(22) == nil)
precondition(p.shift(30) == 7)
p.since = 40                       // paused now
precondition(p.shift(39) == 7)
precondition(p.shift(41) == nil)
precondition(p.total(at: 45) == 12)
let d = UserDefaults(suiteName: "recorder-check")!
p.save(d)
precondition(Pauses.load(d) == p)
p.since = nil
p.save(d)
precondition(Pauses.load(d) == p)
print("pauses: ok")
