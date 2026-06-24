# Nexubot Testing & Validation Protocol

This document defines the strict backtesting standards required before accepting any code change, parameter optimization, or strategy removal into the production branch of Nexubot.

MetaTrader 5 relies heavily on tick interpolation when high-quality history is unavailable. For tight SMC (Smart Money Concepts) systems relying on specific Order Block or FVG sweeps, interpolated ticks will generate **false positive profitability**.

## 1. The Canonical Test Window & Tick Quality

- **Ground Truth Window:** All performance decisions must be based on a **rolling 6-Month window**.
- **Minimum Tick Quality:** The strategy tester MUST report a tick quality of **≥ 85%**.
- **Why:** Due to broker historical data limits (e.g., Exness MT5), pulling 1-year data often results in ~45% tick quality. Backtests below 85% quality are strictly invalid for determining edge or Expected Value (EV).

## 2. Dual-Period Cross-Validation

When assessing the viability of a specific algorithmic setup (e.g., Major Swing Sweep, IFVG Re-Test), use a dual-period approach with strict separation of concerns:

- **The 6-Month Test (High Quality):** Use this EXCLUSIVELY for performance metrics. Win rate, net profit, maximum drawdown, and average $/trade must be validated here.
- **The 1-Year Test (Low Quality):** Use this EXCLUSIVELY for frequency observation. Because 1-year data contains multiple macro-economic regimes (e.g., prolonged bull runs vs. heavy ranging), use it to see _how often_ a strategy fires. **Never use the 1-Year test to judge profitability.**

## 3. Pre-Commit Validation Checklist

Before treating any backtest result as actionable or pushing a new V-series update, confirm the following:

- [ ] **Tick Quality Verified:** The core performance test utilized ≥85% real ticks.
- [ ] **Sample Size Gate:** Ignore performance metrics for any sub-strategy that generated `< 20 trades` in the test window. Let it accumulate data.
- [ ] **Throttle Check:** Check the percentage of trades taken at minimum lot size (0.01). If the min-lot rate spikes above 20-25%, the EA is spending too much time in the `InpMaxLossStreak` penalty box, indicating a structurally flawed sub-strategy is bleeding capital.
- [ ] **Funnel Diagnostics:** Review the `Nexubot_Diagnostics_[Symbol].csv` file. Ensure "No strategy qualified" is appropriately distributed and that no single filter (e.g., "PD/HTF blocked") is erroneously choking valid setups.
- [ ] **Outcome Ratios:** Ensure the `Full-SL` rate remains below 65%. If it climbs higher, evaluate whether `InpTP1Ratio` needs to be pulled closer to entry to secure Breakeven protection faster.
