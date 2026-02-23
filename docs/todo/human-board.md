# Human Board

> Human writes objectives and constraints here.
> VA Auto-Pilot reads this at the start of every cycle.
> Processed items must be marked `[x]`, never deleted.

---

## Instructions (highest priority)
- [ ] Add direct instructions here.

[x] 让 Claude code 和 codex 交叉 review 改进，先让他们理解这套哲学，然后进行改进，直到两个都互相挑不出毛病为止，要充分考虑到模型的强大，不要写死各种东西限制它们的发挥，另外多视角这件事我希望不只是我们能定义，而且应该提示模型可以根据当前的需求场景临时定义最需要最合适的视角，不要给予假设和限定，但是在定义视角的时候必须要充分考虑当前的真实约束条件，以及锚点，让合适的视角自然的涌现，一切问题都是分类问题，可分的前提是给予了正确的约束条件，如果锚点对了，问题迎刃而解，如果解决遇到问题，那么就是视角和锚点错了，要换视角，换锚点。这是本项目的设计哲学。写完就推送就好了，最好自己吃自己的狗粮来验证。
> Processed 2026-02-23: Rewrote Multi-Perspective Review in va-auto-pilot-protocol.md. Two independent cross-reviews (adversarial adopter + protocol designer) each found 3 CRITICALs. All 6 CRITICALs resolved: added anchor identification guard, replaced undefined "confidence" with concrete completion condition, bounded review loop with 3-cycle cap, made "change anchor" a bounded procedure ref, added perspective count heuristic, specified re-review = full perspective set. Template synced. Pushed.

## Feedback (to fold into next cycle)
- Add product feedback and bug reports here.

## Direction (long-term)
- Add strategic direction here.
