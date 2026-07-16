## 1. Decide mitigation level
- [ ] 1.1 Product decision: ship bounded-wait mitigation OR document known limitation
- [ ] 1.2 If doc-only, write the limitation note and skip remaining tasks

## 2. Implement bounded wait (if mitigation chosen)
- [ ] 2.1 Replace `fetch(eval_task)` with `timedwait` bounded at `max_eval_time_ms`
- [ ] 2.2 Release eval slot on timeout before waiting for task
- [ ] 2.3 Track zombie tasks that continue past timeout

## 3. Document the hard bound
- [ ] 3.1 Add doc note that true hard bound requires process isolation (Malt.jl heavy sessions)
- [ ] 3.2 Mention in server startup log if `max_eval_time_ms` is near hardware limit
