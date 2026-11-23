# Gold Sweep SMC EA

An Expert Advisor for MetaTrader 5 that trades XAUUSD with a Smart Money Concepts entry chain: liquidity sweep, change of character, break of structure, then a retest of the fair value gap or order block left behind.

Written by **Fazla Rabbi**. It is a bar-for-bar port of my Pine Script v6 strategy "Gold Sweep–CHoCH SMC Strategy", built for the 5-minute gold chart.

## How it trades

Each step must happen in order. If a setup misses its time window, it is dropped.

1. **Sweep.** Price wicks through a liquidity level and closes back inside it. Levels checked:
   - local swing highs/lows, including equal highs/lows
   - confirmed 15-minute swings
   - the last completed Asia, London and New York AM session highs/lows
   - the previous day's high/low
2. **CHoCH.** A displacement candle closes through the swing that existed before the sweep.
3. **BOS.** A second displacement close breaks a new swing that formed after the CHoCH.
4. **Zone.** The EA stores the first fair value gap at least 0.3 ATR in size after the BOS, and the order block from the CHoCH leg.
5. **Retest.** A candle wicks into the zone and closes back out of it. It must sit in discount (longs) or premium (shorts) of the dealing range.
6. **Confirmation.** Within 3 bars, a strong candle closes beyond the retest candle's high (longs) or low (shorts).

Then the gates. All of them must pass:
- the H4 and H1 trends agree (EMA 50 or swing structure)
- a 15-minute sweep happened in the same direction
- the bar is inside an allowed session (London or New York AM by default)
- the stop is between 0.5 and 5 ATR
- there is at least 1.5R of room to the nearest opposing liquidity
- the daily trade count and daily loss limits are not hit

## Exits

| Leg | Size | Target |
|---|---|---|
| TP1 | 33% | Nearest structure between 1R and 1.75R, else 1R |
| TP2 | 33% | Nearest structure from 2R, else 2R |
| TP3 | Rest | Next opposing liquidity beyond TP2, else 3R, capped at 6R |

- The stop sits just beyond the sweep extreme.
- After TP1 the stop moves to breakeven.
- After TP2 the stop trails behind confirmed swings. It only ever tightens.
- An optional time stop closes the trade if TP1 is not reached within N bars.

The broker holds the stop and the final target. The EA closes the TP1 and TP2 legs itself when price touches them. If the position is too small to split into three, the whole trade exits at TP2.

## Install

1. Copy `GoldSweepSMC_EA.mq5` into `MQL5/Experts/` (in MT5: File → Open Data Folder).
2. Open it in MetaEditor and press Compile.
3. Attach it to an **XAUUSD M5** chart and turn on Algo Trading.

## Before you run it

- **Set the session clock.** `Server time minus New York time` defaults to `7`. That matches most gold brokers, whose server clock is GMT+2 in winter and GMT+3 in summer. If your broker uses a different clock, change this input or every session window will be wrong.
- **History.** The EA replays the last 3000 bars at start to rebuild its state. It also needs H4, H1, M15 and D1 history for the symbol.
- **Sizing.** The default is 0.5% of equity per trade. Fixed cash risk and fixed lots are also available.
- **Expect few trades.** Every filter is on by default and the chain is strict. Run the Strategy Tester ("Every tick based on real ticks") and loosen filters there before going live.

## Differences from the Pine version

- The Pine script fills at the close of the signal bar. The EA fills at market on the next tick.
- ATR uses Pine's RMA smoothing, not MT5's built-in SMA ATR, so stops match the Pine numbers.
- Not ported: chart drawings, the status table, and the VWAP trend method.
- Exit state lives in memory. After a terminal or EA restart, an open trade keeps its broker-side stop and target, but partial exits, breakeven and the trail stop running for that trade.

## Disclaimer

This is research code. Nothing here is financial advice, and past results do not predict future ones. Test on a demo account first. You are responsible for anything it does on a live account.

## License

[Mozilla Public License 2.0](LICENSE). Copyright 2026 Fazla Rabbi.
