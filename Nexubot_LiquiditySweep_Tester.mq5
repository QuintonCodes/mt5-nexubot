//+------------------------------------------------------------------+
//|                                     Nexubot_LiquiditySweep_Tester.mq5 |
//|                                                                  |
//|  Architecture: Isolated Liquidity Sweep strategy for optimization.|
//|  Strips out all POI, FVG, and secondary strategy logic to focus   |
//|  purely on Tier 2-3 sweeps and BOS structure confirmation.        |
//|                                                                  |
//|  v1.01 Fix Log:                                                  |
//|  [FIX-01] BOS one-shot detection via g_last_break_level tracking |
//|  [FIX-02] Sweep/BOS counters now update on EVERY bar (not just   |
//|           when session active and no position is open)            |
//|  [FIX-03] Round number sweep — price-appropriate step sizes,     |
//|           actual wick penetration + close reclaim required,       |
//|           correct directional assignment from penetration side    |
//|  [FIX-04] SL anchored to g_recent_sweep_level (swept price),     |
//|           not to the current bar's high/low                       |
//|  [FIX-05] Sweep counter is_new_sweep check prevents constant      |
//|           reset during 5-bar re-detection window                  |
//|  [FIX-06] Spread filter now applied in RunMarketAnalysis()        |
//|  [FIX-07] Trade timeout management added to ManagePosition()      |
//|  [FIX-08] InpMinSweepTier default corrected from 1 to 2          |
//|  [FIX-09] g_sweep_consumed prevents double-entry on same sweep    |
//|  [FIX-10] CalculateSLTP suggested_sl upper bound tightened to cap |
//+------------------------------------------------------------------+

#property copyright "Nexubot Systems © 2026"
#property link      "https://github.com/QuintonCodes/mt5-nexubot"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==========================================================================
//  SECTION 1: INPUT PARAMETERS
//==========================================================================

//--- Risk Management
input group           "==== RISK MANAGEMENT ===="
input double          InpRiskPercent        = 2.0;    // Risk per trade (% of balance)
input double          InpMaxLotSize         = 1.0;    // Hard cap on lot size
input double          InpMinRR              = 1.5;    // Min structural R/R before entry
input double          InpMaxRR              = 5.0;    // Hard cap on structural R/R to prevent over-extension
input bool            InpUseDynamicRisk     = true;   // Scale risk by account size tiers

//--- Entry Filters (The Strict Funnel)
input group           "==== ENTRY SIGNAL FILTERS ===="
// [FIX-08] Default corrected from 1 -> 2. Strategy_LiquiditySweep() requires Tier2+
// internally, so defaulting to 1 was misleading and allowed internal sweeps to
// pass the RunMarketAnalysis() gate before being silently rejected downstream.
input int             InpMinSweepTier       = 2;      // Min liquidity sweep tier (2=Major, 3=Daily)
input bool            InpRequireHTFAlign    = true;   // Require H1 trend aligned to signal
input bool            InpRequireBOS         = true;   // Require BOS or CHoCH confirmation
input bool            InpSessionFilter      = true;   // Only trade during active killzones
// [FIX-06] Spread filter is now actually enforced in RunMarketAnalysis()
input int             InpMaxSpreadPoints    = 1000;    // Max allowed spread in points (0=off)

//--- ATR & Volatility
input group           "==== ATR & VOLATILITY ===="
input int             InpATRPeriod          = 14;     // ATR calculation period
input int             InpATREMAPeriod       = 48;     // ATR EMA period (expansion baseline)
input double          InpMinVolExpansion    = 0.7;   // Optimal ATR expansion ratio (full risk)
input double          InpMinVolFloor        = 0.7;   // Absolute minimum expansion ratio (scaled risk floor)
input double          InpSLMultiplierBase   = 1.0;    // Base SL ATR multiplier
input double          InpSLMultiplierHVol   = 1.4;    // SL ATR multiplier for volatile assets
input double          InpMaxSLCapATR        = 2.0;    // Max SL cap (x ATR) — hard ceiling
input double          InpTPMultiplier       = 4.0;    // Base TP ATR multiplier

//--- SMC Structure Settings
input group           "==== SMC STRUCTURE DETECTION ===="
input double          InpSweepSLBufferATR   = 0.5;   // SL buffer below swept level for Daily sweeps (x ATR)
input int             InpPivotLookback      = 15;      // Pivot detection window (bars each side)
input int             InpStructureLookback  = 200;    // Structure detection depth (bars)
input int             InpMajorSwingPeriod   = 50;     // Major swing lookback (bars)
input int             InpSweepRecencyBars   = 48;     // Max bars since a Tier2+ sweep to remain "active"
input int             InpBOSRecencyBars     = 12;     // Max bars since a BOS/CHoCH to remain "active"
input int             InpSignalCooldownBars = 1;      // Min bars to wait after a trade before a new entry

//--- Session Times  (Adjust to your broker's server timezone offset)
input group           "==== SESSION TIMES (SERVER TIME) ===="
input int             InpAsianStart         = 1;      // Asian session start hour
input int             InpAsianEnd           = 10;     // Asian session end hour
input int             InpLondonStart        = 8;      // London session start hour
input int             InpLondonEnd          = 18;     // London session end hour
input int             InpNYStart            = 14;     // New York session start hour
input int             InpNYEnd              = 23;     // New York session end hour

//--- Multi-TP Exit Management
input group           "==== MULTI-TP EXIT MANAGEMENT ===="
input double          InpTP1Ratio           = 0.33;   // TP1 = % of full TP3 distance (partial close trigger)
input double          InpTP1PartialVol      = 0.50;   // Percentage of original lot to close at TP1
input double          InpTP2Ratio           = 0.66;   // TP2 = % of full TP3 distance (trail-to-TP1 trigger)
input double          InpBEBufferATR        = 0.15;   // Breakeven buffer above entry (x ATR)
// [FIX-07] Timeout is now enforced in ManagePosition()
input int             InpMaxTradeMins       = 240;    // Max trade duration (minutes) before forced close

//--- Logging & Notifications
input group           "==== NOTIFICATIONS ===="
input bool            InpVerboseLog         = true;   // Print verbose debug logs
input ulong           InpMagicNumber        = 20260701; // EA magic number

//==========================================================================
//  SECTION 2: CONSTANTS & STRUCTS
//==========================================================================

#define ZONE_BULL 0
#define ZONE_BEAR 1

#define SWEEP_NONE     0
#define SWEEP_INTERNAL 1
#define SWEEP_MAJOR    2
#define SWEEP_DAILY    3

#define STRUCT_FLAT 0
#define STRUCT_BULL 1
#define STRUCT_BEAR 2

struct SStructureInfo {
    int    structure;   // STRUCT_BULL / STRUCT_BEAR / STRUCT_FLAT
    int    bos_dir;     // Direction of the most recent BOS
    int    choch_dir;   // Direction of the most recent CHoCH
    double last_high;   // Most recent confirmed pivot high
    double last_low;    // Most recent confirmed pivot low
    double prev_high;   // Second pivot high
    double prev_low;    // Second pivot low
    double pd_array;    // 0.0=full discount, 1.0=full premium
    bool   valid;       // Data is reliable
};

struct SSignal {
    bool   valid;
    int    direction;       // ZONE_BULL or ZONE_BEAR
    double suggested_sl;    // Strategy-supplied raw SL level (anchored to swept level)
    string strategy_name;
    string diagnostic;      // Failure reason for telemetry
};

struct SPositionState {
    bool     active;
    ulong    ticket;
    bool     is_long;
    double   entry_price;
    double   initial_volume;
    double   current_sl;
    double   tp1;
    double   tp2;
    double   tp3;
    bool     tp1_hit;
    bool     tp2_hit;
    bool     be_set;
    double   atr_at_entry;
    datetime open_time;
    string   strategy_name;
    bool     timeout_logged; // Guards against sending duplicate close orders on timeout
};

struct SSessionInfo {
    bool   is_active;
    string session_name;
    double multiplier;
    bool   is_london_session;
};

//==========================================================================
//  SECTION 3: GLOBAL STATE
//==========================================================================

CTrade        g_trade;
CPositionInfo g_position_info;

int g_h_atr      = INVALID_HANDLE;
int g_h_atr_ema  = INVALID_HANDLE;
int g_h_ema50_h1 = INVALID_HANDLE;
int g_h_ema200_h1= INVALID_HANDLE;

SStructureInfo g_structure;
double g_htf_trend   = 0.0;
double g_current_atr = 0.0;
double g_pdh         = 0.0;
double g_pdl         = 0.0;
double g_asian_high  = 0.0;
double g_asian_low   = 0.0;

SPositionState g_pos_state;

datetime g_last_bar_time   = 0;
string   g_last_manage_reason = "";
datetime g_last_spread_log    = 0;

int    g_bars_since_last_signal = 9999;
int    g_bars_since_sweep       = 9999;
int    g_recent_sweep_tier      = SWEEP_NONE;
double g_recent_sweep_depth     = 0.0;
int    g_recent_sweep_dir       = -1;
// [FIX-04 / FIX-05] Stores the actual price level swept (e.g. PDL, swing low).
// Used to anchor SL correctly and to detect whether a re-detected sweep is a
// new event or just the same wick re-appearing in the 5-bar rolling window.
double g_recent_sweep_level     = 0.0;

int    g_bars_since_break  = 9999;
int    g_recent_break_dir  = STRUCT_FLAT;
// [FIX-01] Tracks which structural price level was last broken.
// BOS counter only resets when a NEW structural level is crossed,
// preventing perpetual resets on every bar that stays above/below an old pivot.
double g_last_break_level  = 0.0;

// [FIX-09] Set TRUE after a trade is taken on a sweep; cleared only when a
// genuinely new sweep or new BOS is detected. Prevents double-entry on the
// same sweep event if the first trade closes quickly within the recency window.
bool   g_sweep_consumed    = false;

string g_volatile_ids[] = {"XAU", "XAG", "BTC", "ETH", "US30", "NAS", "SPX", "UK100", "GER40"};

//==========================================================================
//  SECTION 4: UTILITY FUNCTIONS
//==========================================================================

void Log(const string msg, bool verbose_only = false) {
    if (verbose_only && !InpVerboseLog) return;
    PrintFormat("[SweepTester] %s", msg);
}

/// @brief Throttles repeated identical skip-reason logs to once per hour per reason.
void PrintThrottledSkipReason(string reason) {
    static string   tracked_reasons[20];
    static datetime tracked_times[20];
    static int      track_count = 0;

    datetime current_time = TimeCurrent();
    int idx = -1;
    for (int i = 0; i < track_count; i++) {
        if (tracked_reasons[i] == reason) { idx = i; break; }
    }
    if (idx == -1) {
        if (track_count < 20) { idx = track_count; tracked_reasons[idx] = reason; tracked_times[idx] = 0; track_count++; }
        else { idx = 0; }
    }
    if (current_time - tracked_times[idx] >= 3600) {
        Log(reason, true);
        tracked_times[idx] = current_time;
    }
}

/// @brief Suppresses duplicate consecutive position-management log entries.
void PrintThrottledManageLog(string msg) {
    if (msg != g_last_manage_reason) {
        Log(msg, true);
        g_last_manage_reason = msg;
    }
}

/// @brief Returns the ATR from the last confirmed bar, floored at 50 points.
double GetATR() {
    if (g_h_atr == INVALID_HANDLE) return 0.0;
    double MIN_ATR_FLOOR = 50.0 * _Point;
    double atr[];
    ArraySetAsSeries(atr, true);
    ResetLastError();
    if (CopyBuffer(g_h_atr, 0, 1, 1, atr) < 1) return MIN_ATR_FLOOR;
    return MathMax(atr[0], MIN_ATR_FLOOR);
}

/// @brief Returns ATR/ATR-EMA ratio clipped to [0.3, 3.0].
double GetATRExpansionRatio() {
    if (g_h_atr == INVALID_HANDLE || g_h_atr_ema == INVALID_HANDLE) return 1.0;
    double atr_buf[], ema_buf[];
    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(ema_buf, true);
    if (CopyBuffer(g_h_atr, 0, 1, 1, atr_buf) < 1) return 1.0;
    if (CopyBuffer(g_h_atr_ema, 0, 1, 1, ema_buf) < 1 || ema_buf[0] <= 0) return 1.0;
    return MathMax(0.3, MathMin(3.0, atr_buf[0] / ema_buf[0]));
}

/// @brief Returns H1 HTF trend direction: 1.0=bull, -1.0=bear, 0.0=flat.
double GetHTFTrend() {
    if (g_h_ema50_h1 == INVALID_HANDLE || g_h_ema200_h1 == INVALID_HANDLE) return 0.0;
    double ema50[], ema200[];
    ArraySetAsSeries(ema50,  true);
    ArraySetAsSeries(ema200, true);
    if (CopyBuffer(g_h_ema50_h1,  0, 1, 1, ema50)  < 1) return 0.0;
    if (CopyBuffer(g_h_ema200_h1, 0, 1, 1, ema200) < 1) return 0.0;
    if (ema50[0] > ema200[0]) return  1.0;
    if (ema50[0] < ema200[0]) return -1.0;
    return 0.0;
}

/// @brief Returns true if the symbol contains a high-volatility identifier (XAU, BTC, etc).
bool IsHighVolatility(const string symbol) {
    string sym_upper = symbol;
    StringToUpper(sym_upper);
    int n = ArraySize(g_volatile_ids);
    for (int i = 0; i < n; i++) {
        if (StringFind(sym_upper, g_volatile_ids[i]) >= 0) return true;
    }
    return false;
}

/// @brief Returns current session context (active flag, name, quality multiplier).
SSessionInfo GetSessionInfo() {
    SSessionInfo info;
    ZeroMemory(info);
    info.multiplier = 0.90;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;

    bool is_asian  = (InpAsianStart  < InpAsianEnd)  ? (h >= InpAsianStart  && h < InpAsianEnd)  : (h >= InpAsianStart  || h < InpAsianEnd);
    bool is_london = (InpLondonStart < InpLondonEnd) ? (h >= InpLondonStart && h < InpLondonEnd) : (h >= InpLondonStart || h < InpLondonEnd);
    bool is_ny     = (InpNYStart     < InpNYEnd)     ? (h >= InpNYStart     && h < InpNYEnd)     : (h >= InpNYStart     || h < InpNYEnd);

    info.is_active        = is_asian || is_london || is_ny;
    info.is_london_session = is_london;

    if      (is_ny)     { info.session_name = "NY";     info.multiplier = 1.05; }
    else if (is_london) { info.session_name = "LONDON"; info.multiplier = 1.03; }
    else if (is_asian)  { info.session_name = "ASIAN";  info.multiplier = 0.97; }
    else                { info.session_name = "DEAD";   info.multiplier = 0.90; }

    return info;
}

//==========================================================================
//  SECTION 5: MARKET STRUCTURE & SWEEP ANALYSIS
//==========================================================================

void GetDailyLevels(double &pdh, double &pdl) {
    MqlRates d1[];
    ArraySetAsSeries(d1, true);
    if (CopyRates(_Symbol, PERIOD_D1, 0, 3, d1) < 2) { pdh = 0.0; pdl = 0.0; return; }
    pdh = d1[1].high;
    pdl = d1[1].low;
}

void GetAsianRange(double &asian_high, double &asian_low) {
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 250, rates);
    asian_high = 0.0;
    asian_low  = DBL_MAX;

    if (copied < 1) { asian_low = 0.0; return; }

    MqlDateTime today_dt;
    TimeToStruct(rates[0].time, today_dt);

    for (int i = 0; i < copied; i++) {
        MqlDateTime bar_dt;
        TimeToStruct(rates[i].time, bar_dt);
        if (bar_dt.day != today_dt.day || bar_dt.mon != today_dt.mon) break;
        bool is_asian_bar = (InpAsianStart < InpAsianEnd) ?
                            (bar_dt.hour >= InpAsianStart && bar_dt.hour < InpAsianEnd) :
                            (bar_dt.hour >= InpAsianStart || bar_dt.hour < InpAsianEnd);
        if (is_asian_bar) {
            asian_high = MathMax(asian_high, rates[i].high);
            asian_low  = MathMin(asian_low,  rates[i].low);
        }
    }
    if (asian_low == DBL_MAX) { asian_high = 0.0; asian_low = 0.0; }
}

double GetRecentLow(const MqlRates &rates[], int start, int n_bars) {
    int total = ArraySize(rates);
    double lo = DBL_MAX;
    for (int i = start; i < MathMin(start + n_bars, total); i++)
        lo = MathMin(lo, rates[i].low);
    return (lo == DBL_MAX) ? 0.0 : lo;
}

double GetRecentHigh(const MqlRates &rates[], int start, int n_bars) {
    int total = ArraySize(rates);
    double hi = 0.0;
    for (int i = start; i < MathMin(start + n_bars, total); i++)
        hi = MathMax(hi, rates[i].high);
    return hi;
}

bool IsPivotHigh(const MqlRates &rates[], int idx, int lookback) {
    int total = ArraySize(rates);
    if (idx - lookback < 1 || idx + lookback >= total) return false;
    double h = rates[idx].high;
    for (int i = 1; i <= lookback; i++) {
        if (rates[idx - i].high >= h) return false;
        if (rates[idx + i].high >= h) return false;
    }
    return true;
}

bool IsPivotLow(const MqlRates &rates[], int idx, int lookback) {
    int total = ArraySize(rates);
    if (idx - lookback < 1 || idx + lookback >= total) return false;
    double lo = rates[idx].low;
    for (int i = 1; i <= lookback; i++) {
        if (rates[idx - i].low <= lo) return false;
        if (rates[idx + i].low <= lo) return false;
    }
    return true;
}

SStructureInfo DetectStructure(const MqlRates &rates[], int total) {
    SStructureInfo result;
    ZeroMemory(result);
    result.valid = false;

    if (total < InpStructureLookback + InpPivotLookback + 1) return result;

    double ph[4]; int ph_count = 0;
    double pl[4]; int pl_count = 0;

    int search_end = MathMin(total - InpPivotLookback - 1, InpStructureLookback);
    for (int i = InpPivotLookback; i < search_end && (ph_count < 4 || pl_count < 4); i++) {
        if (ph_count < 4 && IsPivotHigh(rates, i, InpPivotLookback)) ph[ph_count++] = rates[i].high;
        if (pl_count < 4 && IsPivotLow(rates,  i, InpPivotLookback)) pl[pl_count++] = rates[i].low;
    }
    if (ph_count < 2 || pl_count < 2) return result;

    double last_high = ph[0], prev_high = ph[1];
    double last_low  = pl[0], prev_low  = pl[1];

    result.last_high = last_high;
    result.last_low  = last_low;
    result.prev_high = prev_high;
    result.prev_low  = prev_low;

    bool is_bull = (last_high > prev_high) && (last_low > prev_low);
    bool is_bear = (last_high < prev_high) && (last_low < prev_low);
    result.structure = is_bull ? STRUCT_BULL : (is_bear ? STRUCT_BEAR : STRUCT_FLAT);

    double curr_close    = rates[1].close;
    result.bos_dir   = STRUCT_FLAT;
    result.choch_dir = STRUCT_FLAT;

    if (curr_close > last_high) {
        if (result.structure == STRUCT_BEAR) result.choch_dir = STRUCT_BULL;
        else                                 result.bos_dir   = STRUCT_BULL;
    } else if (curr_close < last_low) {
        if (result.structure == STRUCT_BULL) result.choch_dir = STRUCT_BEAR;
        else                                 result.bos_dir   = STRUCT_BEAR;
    }

    double pd_range  = last_high - last_low;
    result.pd_array  = (pd_range > 0) ? MathMax(0.0, MathMin(1.0, (curr_close - last_low) / pd_range)) : 0.5;
    result.valid = true;
    return result;
}

/// @brief [FIX-03] Detects if the last 5 bars swept a significant round number
///        level and closed back through it. Uses price-magnitude-appropriate step
///        sizes so Gold ($3000) checks $50 levels, not the original $10 levels
///        which fired on nearly every bar. Requires actual wick penetration AND
///        close reclaim on the correct side. Assigns direction from penetration
///        side (not from the candle's open-close direction as before).
///
/// @param close_price  The last closed bar's close price.
/// @param rec_hi5      The highest high across the last 5 closed bars.
/// @param rec_lo5      The lowest low across the last 5 closed bars.
/// @param atr          Current ATR value.
/// @param out_dir      [Output] ZONE_BULL (swept below, closed above) or ZONE_BEAR.
/// @return true if a valid round number sweep is detected.
bool IsRoundNumberSweep(double close_price, double rec_hi5, double rec_lo5,
                         double atr, int &out_dir) {
    out_dir = -1;
    if (close_price <= 0.0 || atr <= 0.0) return false;

    // Select a step size that maps to significant round number levels for the
    // instrument's price range. Gold (~$3000) → $50 levels; mid-range ($100) → $5;
    // forex majors (~$1) → $0.10. The original step of magnitude/100 gave $10
    // for Gold, which fired on almost every bar.
    double step;
    if      (close_price >= 10000.0) step = 500.0;
    else if (close_price >= 1000.0)  step = 50.0;
    else if (close_price >= 100.0)   step = 5.0;
    else if (close_price >= 10.0)    step = 1.0;
    else if (close_price >= 1.0)     step = 0.10;
    else                             step = 0.01;

    double closest_round = MathRound(close_price / step) * step;

    // Penetration bounds: wick must meaningfully pierce the level without it
    // being a full breakout (which would not be a sweep reversal play).
    double min_penetration = atr * 0.08;  // Filters spread noise / shallow ticks
    double max_penetration = atr * 1.20;  // Beyond this it is a breakout, not a sweep

    // Bullish sweep: wick dipped below the round number; close is back above it
    if (rec_lo5 < closest_round && close_price > closest_round) {
        double depth = closest_round - rec_lo5;
        if (depth >= min_penetration && depth <= max_penetration) {
            out_dir = ZONE_BULL;
            return true;
        }
    }

    // Bearish sweep: wick spiked above the round number; close is back below it
    if (rec_hi5 > closest_round && close_price < closest_round) {
        double depth = rec_hi5 - closest_round;
        if (depth >= min_penetration && depth <= max_penetration) {
            out_dir = ZONE_BEAR;
            return true;
        }
    }

    return false;
}

/// @brief Detects the highest-tier liquidity sweep in the most recent 5 closed bars.
///        Priority: SWEEP_DAILY > SWEEP_MAJOR > SWEEP_INTERNAL.
///
/// @param rates       M5 rates array (series order; 0=forming, 1=last closed).
/// @param total       Total bars copied.
/// @param atr         Current ATR.
/// @param tier        [Output] Sweep tier (SWEEP_NONE / MAJOR / DAILY).
/// @param depth_atr   [Output] Penetration depth expressed in ATR multiples.
/// @param sweep_dir   [Output] ZONE_BULL (bullish reversal expected) or ZONE_BEAR.
/// @param swept_level [Output] The actual price level that was swept (e.g. PDL price).
///                    Populated for every detected sweep; used to anchor SL correctly.
void DetectLiquiditySweep(const MqlRates &rates[], int total, double atr,
                           int &tier, double &depth_atr, int &sweep_dir,
                           double &swept_level) {
    tier        = SWEEP_NONE;
    depth_atr   = 0.0;
    sweep_dir   = -1;
    swept_level = 0.0;

    if (total < InpMajorSwingPeriod + 5 || atr <= 0) return;

    // Price context from the last confirmed bar (index 1) and its 5-bar window.
    double close   = rates[1].close;
    double rec_lo5 = GetRecentLow(rates,  1, 5);
    double rec_hi5 = GetRecentHigh(rates, 1, 5);

    // Major 50-period swing levels, shifted 5 bars to prevent any look-ahead
    // contamination from the same bars we are checking for the sweep wick.
    int    shift       = 5;
    double major_lo50  = GetRecentLow(rates,  1 + shift, InpMajorSwingPeriod);
    double major_hi50  = GetRecentHigh(rates, 1 + shift, InpMajorSwingPeriod);

    SSessionInfo session = GetSessionInfo();

    // -----------------------------------------------------------------------
    // TIER 3: Daily PDH/PDL and Asian Session Range Sweeps (highest quality)
    // -----------------------------------------------------------------------

    // Bullish Daily sweep: wick below PDL, close back above PDL
    if (g_pdl > 0.0 && rec_lo5 < g_pdl && close > g_pdl) {
        double depth = (g_pdl - rec_lo5) / atr;
        if (depth >= 0.12) {
            tier        = SWEEP_DAILY;
            depth_atr   = depth;
            sweep_dir   = ZONE_BULL;
            swept_level = g_pdl;
            return;
        }
    }
    // Bearish Daily sweep: wick above PDH, close back below PDH
    if (g_pdh > 0.0 && rec_hi5 > g_pdh && close < g_pdh) {
        double depth = (rec_hi5 - g_pdh) / atr;
        if (depth >= 0.12) {
            tier        = SWEEP_DAILY;
            depth_atr   = depth;
            sweep_dir   = ZONE_BEAR;
            swept_level = g_pdh;
            return;
        }
    }

    // Allow Asian Range sweeps during BOTH London and NY active sessions
    bool is_active_session = (session.session_name == "LONDON" || session.session_name == "NY");

    // Asian range sweeps — restricted to London session (high-probability window)
    if (is_active_session && g_asian_low > 0.0 && rec_lo5 < g_asian_low && close > g_asian_low) {
        double depth = (g_asian_low - rec_lo5) / atr;
        if (depth >= 0.12) {
            tier        = SWEEP_DAILY;
            depth_atr   = depth;
            sweep_dir   = ZONE_BULL;
            swept_level = g_asian_low;
            return;
        }
    }
    if (is_active_session && g_asian_high > 0.0 && rec_hi5 > g_asian_high && close < g_asian_high) {
        double depth = (rec_hi5 - g_asian_high) / atr;
        if (depth >= 0.12) {
            tier        = SWEEP_DAILY;
            depth_atr   = depth;
            sweep_dir   = ZONE_BEAR;
            swept_level = g_asian_high;
            return;
        }
    }

    // -----------------------------------------------------------------------
    // TIER 2: Major 50-Period Swing Sweeps & Round Number Sweeps
    // -----------------------------------------------------------------------

    if (major_lo50 > 0.0 && rec_lo5 < major_lo50 && close > major_lo50) {
        double depth = (major_lo50 - rec_lo5) / atr;
        if (depth >= 0.15) {
            tier        = SWEEP_MAJOR;
            depth_atr   = depth;
            sweep_dir   = ZONE_BULL;
            swept_level = major_lo50;
            return;
        }
    }
    if (major_hi50 > 0.0 && rec_hi5 > major_hi50 && close < major_hi50) {
        double depth = (rec_hi5 - major_hi50) / atr;
        if (depth >= 0.15) {
            tier        = SWEEP_MAJOR;
            depth_atr   = depth;
            sweep_dir   = ZONE_BEAR;
            swept_level = major_hi50;
            return;
        }
    }

    // [FIX-03] Round number sweep: updated signature passes out_dir directly
    // so direction is derived from actual penetration side, not candle color.
    int rn_dir = -1;
    if (IsRoundNumberSweep(close, rec_hi5, rec_lo5, atr, rn_dir)) {
        tier        = SWEEP_MAJOR;
        depth_atr   = 0.5; // Synthetic depth placeholder for round number events
        sweep_dir   = rn_dir;
        // Swept level is the nearest round number rather than a structural swing price.
        // Compute the same closest_round used inside IsRoundNumberSweep for consistency.
        double rn_step;
        if      (close >= 10000.0) rn_step = 500.0;
        else if (close >= 1000.0)  rn_step = 50.0;
        else if (close >= 100.0)   rn_step = 5.0;
        else if (close >= 10.0)    rn_step = 1.0;
        else if (close >= 1.0)     rn_step = 0.10;
        else                       rn_step = 0.01;
        swept_level = MathRound(close / rn_step) * rn_step;
        return;
    }

    // -----------------------------------------------------------------------
    // TIER 1: Internal Structural Pivot Sweeps
    // -----------------------------------------------------------------------

    if (g_structure.valid && g_structure.last_low > 0.0 &&
        rec_lo5 < g_structure.last_low && close > g_structure.last_low) {
        tier        = SWEEP_INTERNAL;
        depth_atr   = (g_structure.last_low - rec_lo5) / atr;
        sweep_dir   = ZONE_BULL;
        swept_level = g_structure.last_low;
        return;
    }
    if (g_structure.valid && g_structure.last_high > 0.0 &&
        rec_hi5 > g_structure.last_high && close < g_structure.last_high) {
        tier        = SWEEP_INTERNAL;
        depth_atr   = (rec_hi5 - g_structure.last_high) / atr;
        sweep_dir   = ZONE_BEAR;
        swept_level = g_structure.last_high;
        return;
    }
}

//==========================================================================
//  SECTION 6: ISOLATED STRATEGY LOGIC
//==========================================================================

/// @brief Core Liquidity Sweep signal generator.
///        Requires: Tier2+ sweep → aligned BOS/CHoCH → matching directions.
///        [FIX-04] SL is now anchored to g_recent_sweep_level (the actual
///        price of the swept level), not to the current bar's high/low. This
///        ensures the stop is placed where the original liquidity pool was,
///        giving the trade room to absorb re-tests without being stopped out
///        prematurely by normal post-BOS price action.
///        [FIX-09] Returns invalid if the sweep has already been consumed by
///        a prior trade in this same sweep context.
SSignal Strategy_LiquiditySweep(const MqlRates &curr, double atr) {
    SSignal sig;
    ZeroMemory(sig);
    sig.valid = false;

    // [FIX-09] Bail immediately if a trade was already taken on this sweep event.
    if (g_sweep_consumed) {
        sig.diagnostic = "Sweep already consumed by active/recent trade";
        return sig;
    }

    // Gate 1: Must have a Tier2+ sweep in context
    if (g_recent_sweep_tier < SWEEP_MAJOR) {
        sig.diagnostic = "No recent Tier2+ sweep";
        return sig;
    }

    // --- NEW LOGIC: Dynamic Recency Validation ---
    // If a valid structural break (BOS) has occurred in the direction of the sweep,
    // the sweep's validity window is doubled. This accounts for the mechanical delay
    // introduced by higher InpPivotLookback settings where a BOS takes longer to confirm.
    int req_sweep_dir = (g_recent_break_dir == STRUCT_BULL) ? ZONE_BULL : ZONE_BEAR;
    bool is_validated_by_bos = (g_bars_since_break <= InpBOSRecencyBars && g_recent_sweep_dir == req_sweep_dir);
    int effective_sweep_limit = is_validated_by_bos ? (InpSweepRecencyBars * 2) : InpSweepRecencyBars;

    // Gate 2: Sweep must be within its (now dynamic) recency window
    if (g_recent_sweep_tier == SWEEP_MAJOR) {
        if (g_bars_since_sweep > effective_sweep_limit) {
            sig.diagnostic = StringFormat("Major sweep too stale (>%d bars)", effective_sweep_limit);
            return sig;
        }
        if (g_recent_sweep_depth < 0.15) {
            sig.diagnostic = "Major sweep depth < 0.15 ATR";
            return sig;
        }
    } else if (g_recent_sweep_tier == SWEEP_DAILY) {
        if (g_bars_since_sweep > effective_sweep_limit) {
            sig.diagnostic = "Daily/Asian sweep too stale";
            return sig;
        }
    }

    // Gate 3: BOS/CHoCH must be aligned
    int bos_dir = g_recent_break_dir;
    if (bos_dir == STRUCT_FLAT || g_bars_since_break > InpBOSRecencyBars) {
        sig.diagnostic = "No recent BOS/CHoCH";
        return sig;
    }

    // Gate 4: Sweep direction must match BOS direction
    if (g_recent_sweep_dir != req_sweep_dir) {
        sig.diagnostic = "Sweep/BOS direction mismatch";
        return sig;
    }

    // --- SL Sizing ---
    // SWEEP_DAILY uses the tighter user-defined buffer.
    // SWEEP_MAJOR uses a wider buffer to survive re-accumulation/noise.
    double atr_buf   = (g_recent_sweep_tier == SWEEP_DAILY) ? (atr * InpSweepSLBufferATR) : (atr * 0.65);
    string strat_name = (g_recent_sweep_tier == SWEEP_DAILY) ? "Daily/Asian Sweep" : "Major Swing Sweep";

    if (bos_dir == STRUCT_BULL) {
        sig.valid         = true;
        sig.direction     = ZONE_BULL;
        sig.strategy_name = strat_name;
        // [FIX-04] SL is placed below the actual swept level (e.g. PDL, swing low),
        // not below the current bar's low which is disconnected from the trade premise.
        // g_recent_sweep_level falls back to curr.low only if no level was tracked.
        sig.suggested_sl  = (g_recent_sweep_level > 0.0)
                            ? (g_recent_sweep_level - atr_buf)
                            : (curr.low - atr_buf);
    } else if (bos_dir == STRUCT_BEAR) {
        sig.valid         = true;
        sig.direction     = ZONE_BEAR;
        sig.strategy_name = strat_name;
        // [FIX-04] Same for shorts: SL above the swept high level.
        sig.suggested_sl  = (g_recent_sweep_level > 0.0)
                            ? (g_recent_sweep_level + atr_buf)
                            : (curr.high + atr_buf);
    }

    return sig;
}

//==========================================================================
//  SECTION 7: EXECUTION & RISK MANAGEMENT
//==========================================================================

double GetRiskCap(double balance, string currency) {
    if (!InpUseDynamicRisk) return InpRiskPercent;
    bool is_zar = (StringFind(currency, "ZAR") >= 0);
    if (is_zar) {
        if (balance < 2000)   return MathMin(InpRiskPercent, 5.0);
        if (balance < 10000)  return MathMin(InpRiskPercent, 4.0);
        if (balance < 100000) return MathMin(InpRiskPercent, 3.0);
        return MathMin(InpRiskPercent, 2.0);
    } else {
        if (balance < 100)   return MathMin(InpRiskPercent, 5.0);
        if (balance < 500)   return MathMin(InpRiskPercent, 4.0);
        if (balance < 5000)  return MathMin(InpRiskPercent, 3.0);
        return MathMin(InpRiskPercent, 2.0);
    }
}

double CalculateLotSize(double entry_price, double sl_price,
                         ENUM_ORDER_TYPE order_type, double session_multiplier = 1.0) {
    double balance         = AccountInfoDouble(ACCOUNT_BALANCE);
    string currency        = AccountInfoString(ACCOUNT_CURRENCY);
    double applied_risk_pct = GetRiskCap(balance, currency);

    double risk_amount  = balance * (applied_risk_pct / 100.0) * session_multiplier;
    double tick_value   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double sl_distance  = MathAbs(entry_price - sl_price);

    if (sl_distance <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0)
        return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double loss_per_lot = (sl_distance / tick_size) * tick_value;
    double lot_size     = risk_amount / loss_per_lot;

    double margin_required = 0.0;
    if (!OrderCalcMargin(order_type, _Symbol, lot_size, entry_price, margin_required)) {
        lot_size = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    } else {
        double free_margin       = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        double max_margin_allowed = free_margin * 0.80;
        if (margin_required > max_margin_allowed) {
            double leverage_ratio = max_margin_allowed / margin_required;
            lot_size = lot_size * leverage_ratio;
        }
    }

    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLotSize);
    double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot_size = MathFloor(lot_size / step) * step;
    return MathMax(min_lot, MathMin(lot_size, max_lot));
}

bool CalculateSLTP(const SSignal &signal, double entry, double atr,
                    double &sl_price, double &tp1_price, double &tp2_price, double &tp3_price) {
    bool   is_long   = (signal.direction == ZONE_BULL);
    double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    bool   is_hv     = IsHighVolatility(_Symbol);
    double sl_mult   = is_hv ? InpSLMultiplierHVol : InpSLMultiplierBase;

    double sl_dist   = MathMax(atr * sl_mult, point * 50.0);

    // Accept the strategy-supplied SL distance when it is meaningful and within cap.
    // [FIX-10] Upper bound tightened from (atr*6.0) to (atr*InpMaxSLCapATR) for
    // consistency — the cap check below would reject anything above the cap anyway,
    // but an explicit upper bound here makes the intent clear and prevents confusing
    // "SL cap exceeded" log entries from values that were never valid to begin with.
    if (signal.suggested_sl > 0.0) {
        double suggested_dist = MathAbs(signal.suggested_sl - entry);
        bool   correct_side   = (is_long && signal.suggested_sl < entry) ||
                                (!is_long && signal.suggested_sl > entry);
        if (correct_side &&
            suggested_dist > atr * 0.35 &&
            suggested_dist <= atr * InpMaxSLCapATR) {
            sl_dist = suggested_dist;
        }
    }

    long   stop_level    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_stop_dist = (double)stop_level * point;
    if (sl_dist < min_stop_dist) sl_dist = min_stop_dist;

    if (sl_dist > atr * InpMaxSLCapATR) {
        PrintThrottledSkipReason("SL cap exceeded. Skipping.");
        return false;
    }

    sl_price = is_long ? (entry - sl_dist) : (entry + sl_dist);

    double pip_buffer   = point * 15.0;
    double safe_mult    = MathMin(InpTPMultiplier, 5.0);
    double actual_min_rr = (signal.strategy_name == "Daily/Asian Sweep") ? 1.8 : InpMinRR;
    double min_tp_dist  = sl_dist * actual_min_rr;

    // TP3 target: prefer structural levels (PDH/PDL, Asian extremes), fall back to ATR multiple.
    double base_tp = 0.0;
    if (is_long) {
        if (g_pdh > 0.0 && (g_pdh - pip_buffer) >= entry + min_tp_dist)
            base_tp = g_pdh - pip_buffer;
        else if (g_asian_high > 0.0 && (g_asian_high - pip_buffer) >= entry + min_tp_dist)
            base_tp = g_asian_high - pip_buffer;
        else
            base_tp = entry + sl_dist * safe_mult;
    } else {
        if (g_pdl > 0.0 && (g_pdl + pip_buffer) <= entry - min_tp_dist)
            base_tp = g_pdl + pip_buffer;
        else if (g_asian_low > 0.0 && (g_asian_low + pip_buffer) <= entry - min_tp_dist)
            base_tp = g_asian_low + pip_buffer;
        else
            base_tp = entry - sl_dist * safe_mult;
    }
    tp3_price = base_tp;

    double actual_tp_dist = MathAbs(tp3_price - entry);
    double current_rr     = (sl_dist > 0.0) ? (actual_tp_dist / sl_dist) : 0.0;

    // Cap R/R to prevent over-extension
    if (current_rr > InpMaxRR) {
        actual_tp_dist = sl_dist * InpMaxRR;
        tp3_price  = is_long ? (entry + actual_tp_dist) : (entry - actual_tp_dist);
        current_rr = InpMaxRR;
    }

    if (current_rr < InpMinRR) {
        PrintThrottledSkipReason("R/R below minimum. Skipping.");
        return false;
    }

    if (is_long) {
        tp1_price = entry + actual_tp_dist * InpTP1Ratio;
        tp2_price = entry + actual_tp_dist * InpTP2Ratio;
    } else {
        tp1_price = entry - actual_tp_dist * InpTP1Ratio;
        tp2_price = entry - actual_tp_dist * InpTP2Ratio;
    }

    return true;
}

bool ExecuteTrade(const SSignal &signal, double sl, double tp1,
                   double tp2, double tp3, double lots, double atr) {
    bool   is_long = (signal.direction == ZONE_BULL);
    double entry   = is_long ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    entry = NormalizeDouble(entry, digits);
    sl    = NormalizeDouble(sl,    digits);
    tp3   = NormalizeDouble(tp3,   digits);

    bool success = is_long
        ? g_trade.Buy(lots,  _Symbol, entry, sl, tp3, StringFormat("NexubotSweep|%s", signal.strategy_name))
        : g_trade.Sell(lots, _Symbol, entry, sl, tp3, StringFormat("NexubotSweep|%s", signal.strategy_name));

    if (!success) {
        Log(StringFormat("Order failed: %d", g_trade.ResultRetcode()));
        return false;
    }

    g_pos_state.active         = true;
    g_pos_state.ticket         = g_trade.ResultOrder();
    g_pos_state.is_long        = is_long;
    g_pos_state.entry_price    = entry;
    g_pos_state.initial_volume = lots;
    g_pos_state.current_sl     = sl;
    g_pos_state.tp1            = NormalizeDouble(tp1, digits);
    g_pos_state.tp2            = NormalizeDouble(tp2, digits);
    g_pos_state.tp3            = NormalizeDouble(tp3, digits);
    g_pos_state.tp1_hit        = false;
    g_pos_state.tp2_hit        = false;
    g_pos_state.be_set         = false;
    g_pos_state.atr_at_entry   = atr;
    g_pos_state.open_time      = TimeCurrent();
    g_pos_state.strategy_name  = signal.strategy_name;
    g_pos_state.timeout_logged = false;

    Log(StringFormat("ENTRY: %s | SL: %.5f | TP3: %.5f | Lots: %.2f",
                      signal.strategy_name, sl, tp3, lots));
    return true;
}

bool IsPositionOpen() {
    if (!g_pos_state.active) return false;
    return g_position_info.SelectByTicket(g_pos_state.ticket);
}

bool ModifyStopLoss(double new_sl) {
    if (!g_position_info.SelectByTicket(g_pos_state.ticket)) return false;
    int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double curr_sl = g_position_info.StopLoss();
    double curr_tp = g_position_info.TakeProfit();
    new_sl = NormalizeDouble(new_sl, digits);

    if ( g_pos_state.is_long && new_sl <= curr_sl) return false;
    if (!g_pos_state.is_long && new_sl >= curr_sl) return false;

    bool ok = g_trade.PositionModify(g_pos_state.ticket, new_sl, curr_tp);
    if (ok) g_pos_state.current_sl = new_sl;
    return ok;
}

/// @brief Manages all open-position lifecycle events: timeout, TP1 partial close,
///        BE move, TP2 trail. Called every tick when g_pos_state.active is true.
///
/// [FIX-07] Timeout management added. If the trade exceeds InpMaxTradeMins, a close
/// order is sent once (guarded by timeout_logged) and no further management logic
/// runs until the position closes and g_pos_state is zeroed by IsPositionOpen().
void ManagePosition() {
    if (!IsPositionOpen()) {
        if (g_pos_state.active) { ZeroMemory(g_pos_state); g_pos_state.active = false; }
        return;
    }

    // [FIX-07] Trade timeout: force-close if position has exceeded the max duration.
    // timeout_logged guards against sending duplicate close orders while waiting
    // for the broker to confirm the closure (can take several ticks).
    int elapsed_mins = (int)((TimeCurrent() - g_pos_state.open_time) / 60);
    if (elapsed_mins >= InpMaxTradeMins) {
        if (!g_pos_state.timeout_logged) {
            Log(StringFormat("TIMEOUT: Forcing close after %d min (max %d min). Strategy: %s",
                              elapsed_mins, InpMaxTradeMins, g_pos_state.strategy_name));
            g_pos_state.timeout_logged = true;
            g_trade.PositionClose(g_pos_state.ticket);
        }
        // Always return while waiting for the timeout close to be confirmed.
        return;
    }

    double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double curr_price = g_pos_state.is_long ? bid : ask;
    int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // --- TP1: Partial close + move SL to breakeven ---
    if (!g_pos_state.tp1_hit) {
        bool hit_tp1 = g_pos_state.is_long
                       ? (curr_price >= g_pos_state.tp1)
                       : (curr_price <= g_pos_state.tp1);
        if (hit_tp1) {
            double step         = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double lots_to_close = MathFloor((g_pos_state.initial_volume * InpTP1PartialVol) / step) * step;
            double be_price     = g_pos_state.is_long
                                  ? (g_pos_state.entry_price + g_pos_state.atr_at_entry * InpBEBufferATR)
                                  : (g_pos_state.entry_price - g_pos_state.atr_at_entry * InpBEBufferATR);
            be_price = NormalizeDouble(be_price, digits);

            if (lots_to_close >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) {
                if (g_trade.PositionClosePartial(g_pos_state.ticket, lots_to_close)) {
                    g_pos_state.tp1_hit = true;
                    if (ModifyStopLoss(be_price)) g_pos_state.be_set = true;
                    PrintThrottledManageLog("TP1 hit: partial close + SL moved to BE");
                }
            } else {
                // Volume too small to partial close — just move to breakeven
                if (ModifyStopLoss(be_price)) {
                    g_pos_state.tp1_hit = true;
                    g_pos_state.be_set  = true;
                    PrintThrottledManageLog("TP1 hit: SL moved to BE (lot too small to partial close)");
                }
            }
        }
    }

    // --- TP2: Trail SL to TP1 level ---
    if (g_pos_state.tp1_hit && !g_pos_state.tp2_hit) {
        bool hit_tp2 = g_pos_state.is_long
                       ? (curr_price >= g_pos_state.tp2)
                       : (curr_price <= g_pos_state.tp2);
        if (hit_tp2) {
            if (ModifyStopLoss(g_pos_state.tp1)) {
                g_pos_state.tp2_hit = true;
                g_pos_state.be_set  = true;
                PrintThrottledManageLog("TP2 hit: SL trailed to TP1");
            }
        }
    }
}

//==========================================================================
//  SECTION 8: MAIN ANALYSIS ENGINE
//==========================================================================

/// @brief Runs on every new M5 bar. Refreshes market context, updates sweep/BOS
///        counters, then (if filters pass) evaluates and executes signals.
///
/// [FIX-02] Market context refresh, structure detection, and sweep/BOS counter
/// updates now happen at the TOP of the function, before any session or position
/// filters. This prevents counters from freezing while a position is open or
/// during dead session hours, which previously caused stale sweep/BOS contexts
/// to appear perpetually fresh once the position closed or the session opened.
///
/// [FIX-01] BOS counter now uses g_last_break_level for one-shot detection.
/// Previously DetectStructure() fired bos_dir on every bar the close stayed above
/// a structural pivot, causing g_bars_since_break to reset to 0 every single bar
/// and effectively disabling the BOS recency gate. Now the counter only resets
/// when a genuinely new structural level is broken.
///
/// [FIX-05] Sweep counter uses is_new_sweep comparison to prevent the same sweep
/// event (which is re-detected across a 5-bar rolling window) from repeatedly
/// resetting g_bars_since_sweep to 0.
void RunMarketAnalysis() {
    g_bars_since_last_signal++;

    // ==========================================================================
    // PHASE 1 — CONTEXT REFRESH (runs every bar, no early exits yet)
    // ==========================================================================

    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 600, rates);
    if (copied < 50) return;

    // Refresh HTF trend and ATR from closed bars
    g_htf_trend   = GetHTFTrend();
    g_current_atr = GetATR();
    GetDailyLevels(g_pdh, g_pdl);
    GetAsianRange(g_asian_high, g_asian_low);

    if (g_current_atr <= 0.0) return;

    // Structure detection on latest confirmed bars
    g_structure = DetectStructure(rates, copied);
    if (!g_structure.valid) return;

    // ==========================================================================
    // PHASE 2 — SWEEP COUNTER UPDATE (every bar, [FIX-02] + [FIX-05])
    // ==========================================================================

    int    sweep_tier    = SWEEP_NONE;
    double sweep_depth   = 0.0;
    int    sweep_dir_det = -1;
    double swept_level   = 0.0;
    DetectLiquiditySweep(rates, copied, g_current_atr, sweep_tier, sweep_depth, sweep_dir_det, swept_level);

    if (sweep_tier >= SWEEP_MAJOR) {
        // Preserve a fresh active Daily sweep when a Major sweep in the same
        // direction is also detected (the Daily context is higher-value).
        bool active_daily = (g_recent_sweep_tier == SWEEP_DAILY   &&
                             g_bars_since_sweep  <= InpSweepRecencyBars &&
                             g_recent_sweep_dir  == sweep_dir_det);

        if (active_daily && sweep_tier == SWEEP_MAJOR) {
            // Keep the active Daily context alive; just age it naturally.
            g_bars_since_sweep++;
        } else {
            // [FIX-05] Determine whether this is a genuinely new sweep event or
            // just the same wick re-appearing in the rolling 5-bar detection window.
            // A "new" sweep is one with a different tier, direction, or a level that
            // has shifted by more than 0.20 ATR from the last recorded swept level.
            bool is_new_sweep = (sweep_tier         != g_recent_sweep_tier)  ||
                                (sweep_dir_det       != g_recent_sweep_dir)   ||
                                (g_recent_sweep_level <= 0.0)                 ||
                                (MathAbs(swept_level - g_recent_sweep_level)  > g_current_atr * 0.20);

            // Always persist the detected sweep metadata
            g_recent_sweep_tier  = sweep_tier;
            g_recent_sweep_dir   = sweep_dir_det;
            g_recent_sweep_depth = sweep_depth;

            if (is_new_sweep) {
                g_recent_sweep_level = swept_level;
                g_bars_since_sweep   = 0;
                g_sweep_consumed     = false; // New sweep unlocks entry
            } else {
                // Same event re-detected: age naturally so the window expires correctly
                g_bars_since_sweep++;
            }
        }
    } else {
        g_bars_since_sweep++;
    }

    // ==========================================================================
    // PHASE 3 — BOS / CHoCH COUNTER UPDATE ([FIX-01])
    // ==========================================================================

    bool has_structure_break = (g_structure.bos_dir   != STRUCT_FLAT) ||
                               (g_structure.choch_dir != STRUCT_FLAT);

    if (has_structure_break) {
        int    new_break_dir   = (g_structure.bos_dir != STRUCT_FLAT)
                                 ? g_structure.bos_dir : g_structure.choch_dir;
        // The reference price of the level that was crossed (last pivot high or low)
        double break_ref_level = (new_break_dir == STRUCT_BULL)
                                 ? g_structure.last_high : g_structure.last_low;

        // [FIX-01] Only treat this as a new break if the direction changed OR if
        // the level crossed is meaningfully different from the last recorded break
        // level (threshold: 0.15 ATR). Without this check, every bar that closes
        // above an old pivot would reset the counter to 0, rendering the BOS
        // recency gate completely ineffective.
        bool is_new_break = (new_break_dir  != g_recent_break_dir) ||
                            (g_last_break_level <= 0.0)             ||
                            (MathAbs(break_ref_level - g_last_break_level) > g_current_atr * 0.15);

        if (is_new_break) {
            g_recent_break_dir  = new_break_dir;
            g_last_break_level  = break_ref_level;
            g_bars_since_break  = 0;
            g_sweep_consumed    = false; // New BOS unlocks re-entry in same sweep context
        } else {
            // Same level still being traded above/below: age the counter
            g_bars_since_break++;
        }
    } else {
        g_bars_since_break++;
    }

    // ==========================================================================
    // PHASE 4 — ENTRY FILTER GATES (after context is up to date)
    // ==========================================================================

    // Gate: Session filter
    SSessionInfo session = GetSessionInfo();
    if (InpSessionFilter && !session.is_active) return;

    // Gate: Existing open position
    if (IsPositionOpen()) return;

    // Gate: Signal cooldown
    if (InpSignalCooldownBars > 0 && g_bars_since_last_signal < InpSignalCooldownBars) return;

    // [FIX-06] Spread gate — was declared as an input but never applied.
    // Executes here rather than inside ExecuteTrade to avoid wasting the SLTP
    // calculation on a trade that will fail at fill due to wide spread.
    if (InpMaxSpreadPoints > 0) {
        double spread_pts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                             SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
        if (spread_pts > (double)InpMaxSpreadPoints) {
            PrintThrottledSkipReason(StringFormat("Spread %.0f pts exceeds max %d. Skipping.",
                                                   spread_pts, InpMaxSpreadPoints));
            return;
        }
    }

    // Gate: Volatility floor
    double atr_expansion = GetATRExpansionRatio();
    if (atr_expansion < InpMinVolFloor) return;
    if (atr_expansion < InpMinVolExpansion) {
        double vol_confidence = MathMax(0.25, MathMin(1.0,
                                (atr_expansion - InpMinVolFloor) / (InpMinVolExpansion - InpMinVolFloor)));
        session.multiplier *= vol_confidence;
    }

    // Gate: HTF alignment
    if (InpRequireHTFAlign && g_htf_trend == 0.0) return;

    // Gate: Minimum sweep tier
    if (InpMinSweepTier > 0 && g_recent_sweep_tier < InpMinSweepTier) return;

    // Gate: BOS/CHoCH recency
    if (InpRequireBOS && g_bars_since_break > InpBOSRecencyBars) return;

    // ==========================================================================
    // PHASE 5 — DIRECTIONAL FILTERS & SIGNAL GENERATION
    // ==========================================================================

    // Premium/Discount array: only long from discount (<60%), short from premium (>40%)
    double pd          = g_structure.pd_array;
    bool   allow_long  = (pd <= 0.60);
    bool   allow_short = (pd >= 0.40);

    // HTF narrows the allowed directions to trend-aligned trades only
    if (InpRequireHTFAlign) {
        if (g_htf_trend != 1.0)  allow_long  = false;
        if (g_htf_trend != -1.0) allow_short = false;
    }

    SSignal signal = Strategy_LiquiditySweep(rates[1], g_current_atr);
    if (!signal.valid) {
        PrintThrottledSkipReason(StringFormat("LiqSweep rejected: %s", signal.diagnostic));
        return;
    }

    if (signal.direction == ZONE_BULL && !allow_long)  return;
    if (signal.direction == ZONE_BEAR && !allow_short) return;

    // ==========================================================================
    // PHASE 6 — SLTP CALCULATION & EXECUTION
    // ==========================================================================

    double entry = (signal.direction == ZONE_BULL)
                   ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl_price = 0.0, tp1 = 0.0, tp2 = 0.0, tp3 = 0.0;

    if (!CalculateSLTP(signal, entry, g_current_atr, sl_price, tp1, tp2, tp3)) return;

    ENUM_ORDER_TYPE order_type = (signal.direction == ZONE_BULL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    double lots = CalculateLotSize(entry, sl_price, order_type, session.multiplier);

    if (lots > 0.0) {
        if (ExecuteTrade(signal, sl_price, tp1, tp2, tp3, lots, g_current_atr)) {
            g_bars_since_last_signal = 0;
            g_sweep_consumed         = true; // [FIX-09] Lock this sweep event
            Log(StringFormat("SIGNAL: %s | %s | Sweep T%d (%d bars) | BOS %d bars | HTF %.0f | PD %.2f",
                              signal.direction == ZONE_BULL ? "LONG" : "SHORT",
                              signal.strategy_name,
                              g_recent_sweep_tier, g_bars_since_sweep,
                              g_bars_since_break, g_htf_trend, pd));
        }
    }
}

//==========================================================================
//  SECTION 9: EVENT HANDLERS
//==========================================================================

int OnInit() {
    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(20);
    g_trade.SetTypeFillingBySymbol(_Symbol);
    g_trade.SetAsyncMode(false);

    g_h_atr       = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
    g_h_atr_ema   = iMA(_Symbol,  PERIOD_M5, InpATREMAPeriod, 0, MODE_EMA, g_h_atr);
    g_h_ema50_h1  = iMA(_Symbol,  PERIOD_H1, 50,  0, MODE_EMA, PRICE_CLOSE);
    g_h_ema200_h1 = iMA(_Symbol,  PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);

    if (g_h_atr == INVALID_HANDLE      || g_h_atr_ema  == INVALID_HANDLE ||
        g_h_ema50_h1 == INVALID_HANDLE || g_h_ema200_h1 == INVALID_HANDLE) {
        Log("Indicator handle creation failed. EA cannot initialise.");
        return INIT_FAILED;
    }

    // Initialise all position and context state
    ZeroMemory(g_pos_state);
    g_pos_state.active = false;

    // [FIX-01 / FIX-04 / FIX-05 / FIX-09] Zero all new tracking globals
    g_recent_sweep_level = 0.0;
    g_last_break_level   = 0.0;
    g_sweep_consumed     = false;

    // Warm up structural context from historical bars before trading starts
    MqlRates tmp[];
    ArraySetAsSeries(tmp, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, InpStructureLookback + 20, tmp);
    if (copied > 5) {
        g_structure   = DetectStructure(tmp, copied);
        g_current_atr = GetATR();
        g_htf_trend   = GetHTFTrend();
        GetDailyLevels(g_pdh, g_pdl);
        GetAsianRange(g_asian_high, g_asian_low);
    }

    g_last_bar_time = 0;

    Log(StringFormat("Nexubot LiquiditySweep Tester v1.01 initialised | Symbol: %s | Magic: %d",
                      _Symbol, (int)InpMagicNumber));
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    if (g_h_atr       != INVALID_HANDLE) IndicatorRelease(g_h_atr);
    if (g_h_atr_ema   != INVALID_HANDLE) IndicatorRelease(g_h_atr_ema);
    if (g_h_ema50_h1  != INVALID_HANDLE) IndicatorRelease(g_h_ema50_h1);
    if (g_h_ema200_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema200_h1);
}

void OnTick() {
    // Manage any open position on every tick for tight TP/timeout response
    if (g_pos_state.active) ManagePosition();

    // All analysis logic is bar-driven (once per confirmed M5 bar close)
    datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
    if (current_bar == g_last_bar_time) return;
    g_last_bar_time = current_bar;

    RunMarketAnalysis();
}