What the strategy actually is

It’s a previous-day-range breakout system on gold, executed with stop-entry orders, with an unusual risk-management layer bolted on top. Once per D1 candle (i.e. at the broker’s server midnight), it reads the prior day’s high and low and places:

a Buy Stop $0.10 above the prior high, and
a Sell Stop $0.10 below the prior low,

each with a fixed $3.00 stop and a target 6× that stop away. Whichever triggers first, the other is deleted (a software OCO), and from then on the trade is managed by a “risk-free at 1:1” rule plus an M15 trailing stop. Everything is flattened Friday at 18:00 server time.

So the thesis is: gold that takes out yesterday’s extreme keeps going. That’s a legitimate, well-known momentum pattern. What the code does with it is where the problems are.

The lifecycle, step by step

OnInit sets the magic number, slippage and filling mode, records the starting balance, and prints a warning if the symbol name doesn’t contain “GOLD” or “XAU”. It doesn’t refuse to run on other symbols.

OnTick runs four things in order: the Friday cutoff, the daily-bar check, position management, and the M15 trailing check. Note that the Friday block returns early, so after 18:00 Friday nothing else in the tick is processed.

New daily bar → ResetDailyCounters() then ProcessDailySignals(). The latter runs five gates in order: Friday-hour block, optional session filter, spread check (SYMBOL_SPREAD ≤ 50 points), daily limits, then it deletes all existing pendings and computes the four prices. Two stop orders go out with ORDER_TIME_DAY expiry.

On fill → OnTradeTransaction fires on DEAL_ADD and the ORDER_DELETE/FILLED case, and wipes every remaining order carrying the magic number.

Management → each tick, ManageOpenPositions detects any new position, stores its entry and original SL in a PositionData array, and once profit ≥ 1× the original risk distance, moves the SL to entry + $0.50 (a “risk-free” breakeven-plus-buffer). On each new M15 bar, UpdateTrailingStops moves the SL to the previous M15 bar’s low (buys) or high (sells), one point beyond, but only upward and only while in profit.

The parameters, with their real values on XAUUSD (2-digit, point = 0.01)
Input	Default	Effective meaning
InpRiskPercent	0.5	0.5% of balance per trade
InpFixedSLPips	30	$3.00 stop (30 × 10 × point)
InpRiskFreeRR	1.0	breakeven at +$3.00
InpInitialTPRatio	6.0	TP at +$18.00
InpMaxLossAmount	10000	lot cap; only binds above ~$2M balance
InpMaxSpread	50	$0.50
InpOrderOffset	10	$0.10 beyond the prior extreme
InpSlippage	30	$0.30
InpMaxDailyTrades	1	see below — inert
InpFridayCloseHour	18	hard flat, server time

Worked example on a $10,000 account: risk = $50, loss per lot at a $3 stop = $300, so lots = 0.16, actual risk $48, target $288.

The problems, in order of how much they matter

1. The stop is roughly one M15 bar wide, not one day wide. Gold’s daily range in current conditions is typically $30–60; the M15 range is $3–6. A $3.00 stop sits inside normal intraday noise. Practically every breakout will be stopped before the move develops. The comments throughout say “300 pips = $30”, so it looks like the default was meant to be 300 and got set to 30. This single number decides whether the strategy is a breakout system or a noise-harvesting machine.

2. The pip conversion is symbol-digits dependent and unsafe. fixedSLDistance = InpFixedSLPips * 10 * point works only on 2-digit gold. On a 3-digit XAUUSD feed (many brokers), point = 0.001 and the same input produces a $0.30 stop. The same fragility applies to InpOrderOffset ($0.01) and the breakeven buffer ($0.05). Nothing validates the digits.

3. The 1:6 target and the trailing stop are contradictory. The trailing stop at the previous M15 low is extremely tight — one point of buffer, i.e. essentially at the low, on an instrument whose M15 swings are dollars. A trade needs to travel $18 to hit the 6R target, but any $3–4 pullback after entry kills it. In practice the realised payoff won’t be anywhere near 1:6; it’ll cluster around breakeven-to-1R. The 6R TP is decoration.

4. The breakeven logic can move the stop backwards. In ManageOpenPositions, the “risk-free” branch sets newSL = entry ± 0.50 and modifies unconditionally. But the M15 trailing may already have pushed the stop to, say, entry + $1.50 while price was between 1R and the breakeven trigger. When price later reaches +$3.00, the EA sets the stop down to +$0.50, giving back $1 of locked profit. It needs newSL = MathMax(newSL, currentSL).

5. Both “daily limit” controls are dead code. ResetDailyCounters() runs immediately before CheckDailyLimits() on every new daily bar, and it resets g_dailyTradeCount to 0 and g_dailyStartBalance to the current balance. So the trade counter is always 0 when tested, and the measured daily loss is always ~0%. Neither InpMaxDailyTrades nor InpMaxDailyLoss can ever block anything. The daily loss would also need equity, not balance, since floating losses don’t touch balance.

6. Positions can stack. The trade counter resets each calendar day and is per-day, not global. If Monday’s breakout runs and is still open Tuesday, Tuesday places a fresh pair and can open a second position. Nothing checks PositionsTotal() before placing orders. Three concurrent positions at 0.5% each is plausible.

7. The OCO is software-only with no fail-safe. If the opposite stop isn’t deleted — a requote, a freeze-level error, or a fast spike that triggers both stops in the same tick — you end up with two positions. On a hedging account that’s double exposure in both directions; on a netting account the second order silently closes the first trade out. There’s no re-check in OnTick to enforce “one position per day maximum”.

8. The DEAL_ADD handler is over-broad. It deletes all magic-number pendings on any deal on the symbol — including a manual trade you place on gold, or the EA’s own position closing. Usually harmless here, but it means unrelated activity can cancel the day’s orders.

9. A failed placement at midnight means no trade all day. IsNewDailyBar() latches g_lastBarTime and the signal function runs exactly once per D1 candle. Server midnight is the worst-spread moment of the day, and the filter allows only $0.50. If that check fails — or the Friday hour gate trips — there’s no retry later in the day. On many brokers this will skip a meaningful fraction of days for reasons unrelated to the strategy.

10. Attaching the EA mid-session back-fills a stale signal. g_lastBarTime starts at 0, so the first tick after attach always counts as a “new daily bar” and places orders based on yesterday’s extremes at, say, 15:00 — after price may have already run. You can end up with a single-sided order set (the buy stop gets rejected because the market is already above it) with no warning that the setup is stale.

11. ORDER_TIME_DAY is not universally supported. Several brokers reject it for pending orders with error 10030, which would leave a valid-looking BuyStop failed log and zero orders. GTC plus explicit deletion is more portable.

12. The $0.10 offset is smaller than typical gold spread. Buy stops trigger on ask and sell stops on bid, so a spread widening of $0.30 at the prior high can trigger the entry with no real breakout at all. The offset should at least exceed normal spread plus slippage.

13. Minor and cosmetic. prevClose and prevOpen are fetched and never used. The PositionData fields originalLots, riskDistance, partialClosed and positionType are written but never read — and the partialClosed comment references a 50%-at-1:2 partial close that was never implemented. g_lastH1BarTime actually holds an M15 time. #property strict is an MQL4 directive with no effect in MQL5. Comment-versus-code mismatches are everywhere (“300 pips”, “1:2 RR = 600 pips”, “$50k default” against a 10000 default), which makes the code hard to trust when tuning. Disabling InpCloseBeforeWeekend also silently disables InpFridayNoNewTrades, because that check is nested inside it. And MathFloor(lots / lotStep) * lotStep risks floating-point truncation (0.03/0.01 may floor to 2), with MathMax(minLot, ...) silently pushing sub-minimum sizes up and breaching the stated risk.

Overall assessment

The idea is sound and the plumbing is mostly reasonable — stop entries, OCO, day-expiry, weekend flat, per-ticket tracking that survives restart. But the configuration as shipped doesn’t express the strategy the comments describe. The stop is 10× too tight relative to intent (and can be 100× too tight on 3-digit feeds), the 1:6 target is unreachable while an M15 trail is running, the breakeven rule can surrender locked profit, and the two risk-limit parameters do nothing at all. Before any tuning, I’d fix the stop distance calculation to be digits-aware, make the daily counters actually persist across the check, add a PositionsTotal() == 0 guard before placing orders, clamp each SL modification so it only ever tightens, and widen the trailing buffer to something comparable to the M15 range.

Want me to write this up as a document, or produce a corrected version of the .mq5 with those fixes applied?

brief it in a more simpler language

What it does

Every day at broker midnight, the EA looks at yesterday’s high and low price on gold. It then places two waiting orders: one to buy if price goes $0.10 above yesterday’s high, one to sell if it goes $0.10 below yesterday’s low. Whichever triggers first, the other gets cancelled. Then it manages the trade until it’s closed.

The numbers

Each trade risks 0.5% of your balance. The stop loss is set just $3 away from entry, and the target is $18 away. When the trade is $3 in profit, the stop moves close to your entry price so you can’t lose. On top of that, every 15 minutes the stop is tightened to just behind the last 15-minute candle. Friday at 6pm server time, everything is closed.

The idea behind it

If gold breaks yesterday’s high, it usually keeps going up. That’s a real pattern traders use, and the code implements it cleanly.

Where it breaks

The $3 stop is the main problem. Gold moves $3 in a few minutes on a normal day — it’s not a day-sized stop, it’s a coffee-break-sized stop. So most trades get knocked out by ordinary noise before the actual move happens. The code comments even say “300 pips,” which suggests the real intended setting was 300, not 30, and someone typed it wrong.

Because the stop is so tight, the $18 target basically never gets reached. And the 15-minute trailing stop is also very tight, so it tends to cut trades early anyway. So the “1:6” target looks impressive on paper but in reality you’ll mostly end up near breakeven.

There’s also a bug where the stop can move backwards. If the trailing stop has already locked in, say, $1.50 of profit, and then price hits the $3 breakeven trigger, the EA resets the stop to $0.50 — giving back money it had already protected.

Two of the safety settings — max trades per day and max daily loss — don’t work at all. The counters get reset to zero right before they’re checked, so they can never block anything. You could end up with several positions open at once if a trade carries over into the next day.

Smaller stuff: the $3 stop becomes $0.30 if your broker uses 3 decimals instead of 2. The $0.10 offset is smaller than a normal gold spread, so it can trigger on spread widening rather than a real breakout. If placing the orders fails at midnight (bad spread, for example), there’s no retry, so you lose the whole day. And if you attach the EA in the middle of the day, it immediately places orders based on yesterday’s prices, which may already be out of date.

The short version

The logic is fine and the plumbing is decent, but as shipped the settings don’t do what the comments say. The stop is ten times too tight, the 1:6 target won’t be reached, the breakeven rule can give back locked profit, and the risk limits are dead. Fix the stop distance to something like $30, make the two daily limits actually work, and clamp the stop so it only ever tightens — then it starts behaving like a real breakout system.
