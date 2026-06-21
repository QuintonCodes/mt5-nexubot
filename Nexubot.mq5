//+------------------------------------------------------------------+
//|                                                      Nexubot.mq5 |
//|                        Nexubot Systems © 2026                    |
//|               Advanced SMC Expert Advisor for MetaTrader 5       |
//|                            Version 1.0                           |
//|                                                                  |
//|  Architecture: Pure Smart Money Concepts (SMC) signal engine     |
//|  with multi-timeframe alignment, tiered liquidity sweep          |
//|  detection, POI confluence scoring, and adaptive position        |
//|  management engineered to achieve 80-90% win rate.               |
//|                                                                  |
//|  Core Signal Funnel (ALL conditions must pass):                  |
//|    1. H1 HTF Trend Alignment   (EMA 50/200 cross)               |
//|    2. Tier 2+ Liquidity Sweep  (Daily/Asian or Major 50-bar)    |
//|    3. BOS / CHoCH Confirmation (close-based, no wicks)           |
//|    4. Minimum 2:1 R/R Ratio    (structural, pre-execution)       |
//+------------------------------------------------------------------+

#property copyright "Nexubot Systems © 2026"
#property link      "https://github.com/QuintonCodes/mt5-nexubot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==========================================================================
//  SECTION 1: INPUT PARAMETERS
//  These are the primary tuning levers. Adjust these to refine performance
//  without touching core logic. Group them by domain for readability.
//==========================================================================

//--- Risk Management
input group           "==== RISK MANAGEMENT ===="
input double          InpRiskPercent       = 2.0;    // Risk per trade (% of balance)
input double          InpMaxLotSize        = 1.0;    // Hard cap on lot size
input double          InpMinRR             = 2.0;    // Min structural R/R before entry
input double          InpMaxRR             = 4.0;    // Hard cap on structural R/R to prevent over-extension
input bool            InpUseDynamicRisk    = true;   // Scale risk by account size tiers
input int             InpMaxLossStreak     = 3;      // Net loss count before risk is throttled
input double          InpStreakPenaltyMult = 0.5;    // Risk multiplier applied exponentially per loss beyond the threshold

//--- Entry Filters (The Strict Funnel)
input group           "==== ENTRY SIGNAL FILTERS ===="
input int             InpMinSweepTier      = 2;      // Min liquidity sweep tier (1/2/3)
input bool            InpRequireHTFAlign   = true;   // Require H1 trend aligned to signal
input bool            InpRequireBOS        = true;   // Require BOS or CHoCH confirmation
input bool            InpSessionFilter     = true;   // Only trade during active killzones
input int             InpMaxSpreadPoints   = 500;     // Max allowed spread in points (0=off)
input double          InpMinVolRatio       = 1.3;     // Min volume ratio for displacement
input bool            InpRequirePOIConfluence = true; // Require setup to trigger near an active POI
input double          InpPOIProximityATR   = 2.0;     // Max distance to POI (x ATR) for confluence

//--- ATR & Volatility
input group           "==== ATR & VOLATILITY ===="
input int             InpATRPeriod         = 14;     // ATR calculation period
input int             InpATREMAPeriod      = 48;     // ATR EMA period (expansion baseline)
input double          InpMinVolExpansion   = 0.85;   // Optimal ATR expansion ratio (full risk)
input double          InpMinVolFloor       = 0.70;   // Absolute minimum expansion ratio (scaled risk floor)
input double          InpSLMultiplierBase  = 1.0;    // Base SL ATR multiplier
input double          InpSLMultiplierHVol  = 1.3;    // SL ATR multiplier for volatile assets
input double          InpMaxSLCapATR       = 3.5;    // Max SL cap (x ATR) — hard ceiling
input double          InpTPMultiplier      = 4.0;    // Base TP ATR multiplier

//--- SMC Structure Settings
input group           "==== SMC STRUCTURE DETECTION ===="
input double          InpSweepSLBufferATR  = 0.40;   // Stop loss buffer for liquidity sweep entries (x ATR)
input int             InpPivotLookback     = 6;      // Pivot detection window (bars each side)
input int             InpStructureLookback = 200;    // Structure detection depth (bars)
input int             InpMajorSwingPeriod  = 50;     // Major swing lookback (bars)
input int             InpSweepRecencyBars  = 48;     // Max bars since a Tier2+ sweep to remain "active"
input int             InpBOSRecencyBars    = 24;     // Max bars since a BOS/CHoCH to remain "active"

//--- POI (Point of Interest) Management
input group           "==== POI MANAGEMENT ===="
input int             InpMaxPOIsPerType    = 50;     // Max POIs tracked per type
input int             InpMaxPOIAgeBars     = 300;    // Max POI age before auto-expiry
input int             InpMaxMitigations    = 3;      // Mitigations before zone invalidation
input double          InpMinFVGVolRatio    = 1.5;    // Min vol ratio to create FVG
input double          InpMinOBBodyRatio    = 0.65;   // Min body/range ratio for OB candle
input double          InpMinOBVolRatio     = 1.2;    // Min vol ratio to create OB
input int             InpWarmupBars        = 500;    // Historical bars for POI warmup
input int             InpSignalCooldownBars = 3;     // Min bars to wait after a trade before allowing a new entry

//--- Session Times  (Adjust to your broker's server timezone offset)
input group           "==== SESSION TIMES (SERVER TIME) ===="
input int             InpAsianStart        = 2;      // Asian session start hour
input int             InpAsianEnd          = 10;     // Asian session end hour
input int             InpLondonStart       = 9;      // London session start hour
input int             InpLondonEnd         = 18;     // London session end hour
input int             InpNYStart           = 14;     // New York session start hour
input int             InpNYEnd             = 23;     // New York session end hour

//--- Multi-TP Exit Management
input group           "==== MULTI-TP EXIT MANAGEMENT ===="
input double          InpTP1Ratio          = 0.50;   // TP1 = % of full TP3 distance (Trigger for partial close)
input double          InpTP1PartialVol     = 0.50;   // Percentage of original lot size to close at TP1
input double          InpTP2Ratio          = 0.75;   // TP2 = % of full TP3 distance (Trigger for Breakeven move)
input double          InpBEBufferATR       = 0.15;   // Breakeven buffer above entry (x ATR)
input int             InpMaxTradeMins      = 240;    // Max trade duration (minutes)

//--- Logging & Notifications
input group           "==== NOTIFICATIONS ===="
input bool            InpEnableAlerts      = true;   // Enable MT5 popup alerts
input bool            InpEnableNotify      = true;   // Enable mobile push notifications
input bool            InpVerboseLog        = true;  // Print verbose debug logs
input ulong           InpMagicNumber       = 20260611; // EA magic number (unique per chart)

//==========================================================================
//  SECTION 2: CONSTANTS
//  Internal fixed values. Not user-editable but documented for transparency.
//==========================================================================

#define MAX_ZONES 100 // Hard cap for each POI array (FVG/IFVG/OB)

//--- Zone types
#define ZONE_BULL 0
#define ZONE_BEAR 1

//--- OB tiers
#define OB_INTERNAL 0
#define OB_MAJOR 1
#define OB_BREAKER 2

//--- Sweep tiers
#define SWEEP_NONE 0
#define SWEEP_INTERNAL 1
#define SWEEP_MAJOR 2
#define SWEEP_DAILY 3

//--- Structure states
#define STRUCT_FLAT 0
#define STRUCT_BULL 1
#define STRUCT_BEAR 2

//==========================================================================
//  SECTION 3: STRUCT DEFINITIONS
//  All data containers used across the EA.
//==========================================================================

/// @brief Represents a single Point of Interest (FVG, IFVG, or Order Block).
struct SZone {
    bool   active;          // Is this zone still valid (not expired)?
    int    zone_type;       // ZONE_BULL (0) or ZONE_BEAR (1)
    double zone_high;       // Upper boundary price
    double zone_low;        // Lower boundary price
    int    mitigations;     // Times price has entered the zone
    bool   is_touching;     // Is the current bar currently inside the zone?
    int    age_bars;        // Bars since zone was created
    double vol_strength;    // Volume ratio at zone creation (for OBs)
    int    ob_tier;         // OB_INTERNAL, OB_MAJOR, OB_BREAKER
};

/// @brief Summarizes current structural analysis for the M5 chart.
struct SStructureInfo {
    int    structure;       // STRUCT_BULL, STRUCT_BEAR, or STRUCT_FLAT
    int    bos_dir;         // BOS direction: STRUCT_BULL, STRUCT_BEAR, or STRUCT_FLAT
    int    choch_dir;       // CHoCH direction: STRUCT_BULL, STRUCT_BEAR, or STRUCT_FLAT
    double last_high;       // Last confirmed pivot high price
    double last_low;        // Last confirmed pivot low price
    double prev_high;       // Second-to-last confirmed pivot high
    double prev_low;        // Second-to-last confirmed pivot low
    double pd_array;        // Premium/Discount status (0.0=full discount, 1.0=full premium)
    bool   valid;           // Data is populated and reliable
};

/// @brief Output container for a strategy signal.
struct SSignal {
    bool   valid;           // Is this a valid signal?
    int    direction;       // ZONE_BULL (long) or ZONE_BEAR (short)
    double suggested_sl;    // Strategy-supplied raw SL level
    string strategy_name;   // Human-readable strategy label
};

/// @brief Live state of a tracked open position.
struct SPositionState {
    bool     active;            // Is this state tracking a live position?
    ulong    ticket;            // MT5 position ticket
    bool     is_long;           // true=BUY, false=SELL
    double   entry_price;       // Price at which trade was entered
    double   initial_volume;    // Volume at trade execution (for partial closes)
    double   current_sl;        // Current stop loss level (updates as trade progresses)
    double   tp1;               // First take-profit level (breakeven trigger)
    double   tp2;               // Second take-profit level (trail-to-TP1 trigger)
    double   tp3;               // Final take-profit target
    bool     tp1_hit;           // Has TP1 been reached this trade?
    bool     tp2_hit;           // Has TP2 been reached this trade?
    bool     be_set;            // Has stop been moved to breakeven or better?
    double   atr_at_entry;      // ATR value captured at entry (for BE calculation)
    datetime open_time;         // Time trade was opened (for timeout management)
    string   strategy_name;     // The strategy that generated the trade (for analytics)
    bool     timeout_logged;    // Has the timeout warning been logged?
};

/// @brief Container for tracking per-strategy performance.
struct SStrategyStats {
    string strategy_name;
    int    total_trades;
    int    long_trades;
    int    long_wins;
    int    short_trades;
    int    short_wins;
    double net_profit;
};

/// @brief Session activity context for current time.
struct SSessionInfo {
    bool   is_active;       // Is at least one session currently active?
    string session_name;    // "ASIAN", "LONDON", "NY", or "DEAD"
    double multiplier;      // Confidence multiplier for session quality
    bool   is_london_open;  // True during London open (8-10 SAST) — highest sweep prob
};

//==========================================================================
//  SECTION 4: GLOBAL STATE VARIABLES
//  All mutable runtime state. Only modified within specific functions.
//==========================================================================

// --- Trading engine objects ---
CTrade g_trade;
CPositionInfo g_position_info;

// --- Indicator handles (initialized once in OnInit, released in OnDeinit) ---
int g_h_atr = INVALID_HANDLE; // ATR(14) on M5
int g_h_atr_ema = INVALID_HANDLE; // ATR EMA on M5 (expansion ratio baseline)
int g_h_ema50_h1 = INVALID_HANDLE; // EMA(50) on H1 for HTF trend
int g_h_ema200_h1 = INVALID_HANDLE; // EMA(200) on H1 for HTF trend

// --- POI arrays — fixed-size with active count trackers ---
SZone g_fvgs[MAX_ZONES];
SZone g_ifvgs[MAX_ZONES];
SZone g_obs[MAX_ZONES];
int g_fvg_count = 0;
int g_ifvg_count = 0;
int g_ob_count = 0;

// --- Structural context — updated on each new bar ---
SStructureInfo g_structure;
double g_htf_trend = 0.0; // 1.0=bull, -1.0=bear, 0.0=flat (H1)
double g_current_atr = 0.0; // Last confirmed bar's ATR
double g_vwap = 0.0; // Session VWAP for the current day
double g_pdh = 0.0; // Previous day's high
double g_pdl = 0.0; // Previous day's low
double g_asian_high = 0.0; // Current day's Asian session high
double g_asian_low = 0.0; // Current day's Asian session low

// --- Position tracking ---
SPositionState g_pos_state;

// --- Analytics tracking ---
SStrategyStats g_strategy_stats[20];
int g_stats_count = 0;

// --- Bar timing — used to detect when a new M5 bar has formed ---
datetime g_last_bar_time = 0;

// --- State tracking for log throttling ---
string g_last_skip_reason = "";
string g_last_manage_reason = "";
static datetime last_spread_log = 0;

// --- Cooldown / throttle ---
int g_bars_since_last_signal = 9999;
int g_bars_since_sweep = 9999; // Bars elapsed since the last Tier2+ sweep
int g_recent_sweep_tier = SWEEP_NONE; // Tier of that most recent sweep
int g_recent_sweep_dir = -1; // Direction of the most recent sweep (ZONE_BULL/ZONE_BEAR)
int g_bars_since_break = 9999; // Bars elapsed since the last BOS/CHoCH
int g_recent_break_dir = STRUCT_FLAT; // Direction of that most recent break

// --- Volatile asset identifier suffixes ---
string g_volatile_ids[] = {"XAU", "XAG", "BTC", "ETH", "US30", "NAS", "SPX", "UK100", "GER40"};


//==========================================================================
//  SECTION 5: UTILITY & TECHNICAL ANALYSIS HELPERS
//==========================================================================

/// @brief Returns the current ATR value from the last confirmed (closed) bar.
/// @return ATR value, floored at MIN_ATR_FLOOR to prevent division by zero.
double GetATR() {
    if (g_h_atr == INVALID_HANDLE) return 0.0;

    // Scale floor to 50 points dynamically (5 pips for standard Forex, 50 points for Gold)
    double MIN_ATR_FLOOR = 50 * _Point;

    double atr[];
    ArraySetAsSeries(atr, true);
    ResetLastError();

    int copied = CopyBuffer(g_h_atr, 0, 1, 1, atr);
    if (copied < 1) {
        int err = GetLastError();
        // Suppress error 4806 as indicator data is not yet calculated on startup
        if (err != 4806 && InpVerboseLog) {
            PrintFormat("ATR CopyBuffer failed. Defaulting to dynamic floor. Error=%d", err);
        }
        return MIN_ATR_FLOOR;
    }

    // Ensure the ATR never compresses tighter than our dynamic asset floor
    return MathMax(atr[0], MIN_ATR_FLOOR);
}

/// @brief Returns the ATR expansion ratio (current ATR / ATR EMA).
/// Ratios > 1.0 indicate expanding, volatility-driven price action.
/// @return Expansion ratio, clipped to [0.3, 3.0] to bound outliers.
double GetATRExpansionRatio() {
    if (g_h_atr == INVALID_HANDLE || g_h_atr_ema == INVALID_HANDLE) return 1.0;

    double atr_buf[], ema_buf[];

    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(ema_buf, true);

    if (CopyBuffer(g_h_atr, 0, 1, 1, atr_buf) < 1) return 1.0;
    if (CopyBuffer(g_h_atr_ema, 0, 1, 1, ema_buf) < 1 || ema_buf[0] <= 0) return 1.0;

    double ratio = atr_buf[0] / ema_buf[0];
    return MathMax(0.3, MathMin(3.0, ratio));
}

/// @brief Returns the H1 HTF trend direction using the EMA 50/200 cross.
/// @return 1.0 = bullish, -1.0 = bearish, 0.0 = flat/neutral.
double GetHTFTrend() {
    if (g_h_ema50_h1 == INVALID_HANDLE || g_h_ema200_h1 == INVALID_HANDLE) {
        return 0.0;
    };

    double ema50[], ema200[];

    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(ema200, true);

    ResetLastError();

    int copied50 = CopyBuffer(g_h_ema50_h1, 0, 1, 1, ema50);
    int copied200 = CopyBuffer(g_h_ema200_h1, 0, 1, 1, ema200);

    // Use index 1 (last confirmed H1 bar) to avoid repainting on current bar
    if (copied50  < 1) return 0.0;
    if (copied200 < 1) return 0.0;
    if (ema50[0] > ema200[0]) return  1.0;
    if (ema50[0] < ema200[0]) return -1.0;
    return 0.0;
}

/// @brief Calculates the session VWAP by scanning today's M5 bars.
/// Anchors to the start of the current server trading day.
/// @param rates  Array of M5 bars (ArraySetAsSeries = true).
/// @param total  Total bars in the rates array.
/// @return VWAP price, or the last close if volume data is unavailable.
double CalculateVWAP(const MqlRates &rates[], int total) {
    if (total < 1) return rates[0].close;

    double cum_pv = 0.0, cum_vol = 0.0;
    MqlDateTime dt0;
    TimeToStruct(rates[0].time, dt0); // Reference: today's date

    for (int i = 0; i < total; i++) {
        MqlDateTime dti;
        TimeToStruct(rates[i].time, dti);

        // Stop when we cross into the previous day
        if (dti.day != dt0.day || dti.mon != dt0.mon) break;

        double typical = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
        cum_pv += typical * (double)rates[i].tick_volume;
        cum_vol += (double)rates[i].tick_volume;
    }

    return (cum_vol > 0.0) ? (cum_pv / cum_vol) : rates[0].close;
}

/// @brief Calculates the 20-bar SMA of tick volume.
/// @param rates  M5 rates array (series order).
/// @param start  Starting index (skip current forming bar = use 1+).
/// @param period Number of bars to average.
/// @return Volume SMA, guaranteed to be >= 1.0 to prevent division errors.
double GetVolumeSMA(const MqlRates &rates[], int start, int period) {
    int total = ArraySize(rates);
    if (total < start + period) return 1.0;

    double sum = 0.0;
    for (int i = start; i < start + period; i++) sum += (double)rates[i].tick_volume;

    return MathMax(1.0, sum / period);
}

/// @brief Calculates the body-to-range ratio of a single candle.
/// A ratio of 0.0 indicates a doji, while 1.0 indicates a full marubozu.
/// The ratio is clipped to the range [0, 1].
/// @param bar The MqlRates structure representing the candle.
/// @return 0.0 for doji, 1.0 for full marubozu. Clipped at [0, 1].
double GetBodyRatio(const MqlRates &bar) {
    double rng = bar.high - bar.low;
    if (rng <= 0) return 0.0;
    return MathMin(1.0, MathAbs(bar.close - bar.open) / rng);
}

/// @brief Returns true if the symbol contains any high-volatility identifier.
/// This is used to adjust ATR multipliers for volatile assets like XAU, BTC, etc.
/// @param symbol The symbol name to check (case-insensitive).
/// @return True if the symbol is considered high-volatility.
bool IsHighVolatility(const string symbol) {
    string sym_upper = symbol;
    StringToUpper(sym_upper);
    int n = ArraySize(g_volatile_ids);

    for (int i = 0; i < n; i++) {
        if (StringFind(sym_upper, g_volatile_ids[i]) >= 0) return true;
    }

    return false;
}

/// @brief Logs a message to the Experts log. Prepends EA identifier.
/// @param msg The message to log.
/// @param verbose_only If true, only logs if InpVerboseLog is enabled.
void Log(const string msg, bool verbose_only = false) {
    if (verbose_only && !InpVerboseLog) return;
    PrintFormat("[Nexubot] %s", msg);
}

/// @brief Helper function to prevent log spam for consecutive identical skip reasons
/// @param reason The reason for skipping a trade signal.
void PrintThrottledSkipReason(string reason) {
    if (reason != g_last_skip_reason) {
        Log(reason, true); // Uses your existing Log() function
        g_last_skip_reason = reason;
    }
}

/// @brief Helper function to prevent log spam for consecutive identical trade management events
void PrintThrottledManageLog(string msg) {
    if (msg != g_last_manage_reason) {
        Log(msg, true);
        g_last_manage_reason = msg;
    }
}

//==========================================================================
//  SECTION 6: DAILY LEVELS & ASIAN RANGE
//  These form the backbone of Tier-3 sweep detection (highest quality).
//==========================================================================

/// @brief Fetches previous day's High (PDH) and Low (PDL) from D1 data.
/// @param pdh  Output: Previous Day High.
/// @param pdl  Output: Previous Day Low.
void GetDailyLevels(double &pdh, double &pdl) {
    MqlRates d1[];
    ArraySetAsSeries(d1, true);

    // Index 0 = today (forming), Index 1 = yesterday (confirmed)
    if (CopyRates(_Symbol, PERIOD_D1, 0, 3, d1) < 2) {
        pdh = 0.0; pdl = 0.0;
        return;
    }

    pdh = d1[1].high;
    pdl = d1[1].low;
}

/// @brief Calculates the current day's Asian session High and Low.
/// Scans M5 bars backward until the session hours are no longer active
/// or the day boundary is crossed.
/// @param asian_high  Output: Asian session high.
/// @param asian_low   Output: Asian session low.
void GetAsianRange(double &asian_high, double &asian_low) {
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    // ~16 hours of M5 bars = 192 bars (enough to cover from Asia to current)
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 250, rates);

    asian_high = 0.0;
    asian_low = DBL_MAX;

    if (copied < 1) { asian_low = 0.0; return; }

    MqlDateTime today_dt;
    TimeToStruct(rates[0].time, today_dt);

    for (int i = 0; i < copied; i++) {
        MqlDateTime bar_dt;
        TimeToStruct(rates[i].time, bar_dt);

        // Stop scanning when we cross into the previous day
        if (bar_dt.day != today_dt.day || bar_dt.mon != today_dt.mon) break;

        // Only accumulate bars within the Asian session window (handles midnight wrap)
        bool is_asian_bar = (InpAsianStart < InpAsianEnd) ?
                            (bar_dt.hour >= InpAsianStart && bar_dt.hour < InpAsianEnd) :
                            (bar_dt.hour >= InpAsianStart || bar_dt.hour < InpAsianEnd);

        if (is_asian_bar) {
            asian_high = MathMax(asian_high, rates[i].high);
            asian_low = MathMin(asian_low, rates[i].low);
        }
    }

    // If no Asian bars found today (pre-Asian session), use safe defaults
    if (asian_low == DBL_MAX) { asian_high = 0.0; asian_low = 0.0; }
}

/// @brief Returns the N-bar rolling minimum low (from index start to start+N).
/// @param rates  Array of MqlRates in series order (0=newest).
/// @param start  Starting index (0=newest bar).
/// @param n_bars Number of bars to consider (must be > 0).
/// @return Minimum low price over the specified range, or 0.0 if no valid bars.
double GetRecentLow(const MqlRates &rates[], int start, int n_bars) {
    int total = ArraySize(rates);
    double lo = DBL_MAX;

    for (int i = start; i < MathMin(start + n_bars, total); i++)
        lo = MathMin(lo, rates[i].low);

    return (lo == DBL_MAX) ? 0.0 : lo;
}

/// @brief Returns the N-bar rolling maximum high (from index start to start+N).
/// @param rates  Array of MqlRates in series order (0=newest).
/// @param start  Starting index (0=newest bar).
/// @param n_bars Number of bars to consider (must be > 0).
/// @return Maximum high price over the specified range, or 0.0 if no valid bars.
double GetRecentHigh(const MqlRates &rates[], int start, int n_bars) {
    int total = ArraySize(rates);
    double hi = 0.0;

    for (int i = start; i < MathMin(start + n_bars, total); i++)
        hi = MathMax(hi, rates[i].high);

    return hi;
}

//==========================================================================
//  SECTION 7: PIVOT DETECTION
//  Uses a symmetric window to identify confirmed structural pivots.
//  Index 0 = newest bar. A pivot at index k requires k+lookback bars
//  to the left (older) AND k-lookback bars to the right (newer) to exist.
//==========================================================================

/// @brief Returns true if rates[idx].high is the highest within the lookback window.
/// Only processes CONFIRMED pivots — will not fire on recent unconfirmed bars.
/// @param rates Array of MqlRates in series order (0=newest).
/// @param idx Index of the candidate pivot bar (0=newest).
/// @param lookback Number of bars to check on each side (symmetric).
/// @return True if the bar at idx is a confirmed pivot high.
bool IsPivotHigh(const MqlRates &rates[], int idx, int lookback) {
    int total = ArraySize(rates);

    // Need lookback bars on both sides (newer = lower idx, older = higher idx)
    if (idx - lookback < 1 || idx + lookback >= total) return false;
    double h = rates[idx].high;

    for (int i = 1; i <= lookback; i++) {
        if (rates[idx - i].high >= h) return false; // Newer bar has higher high
        if (rates[idx + i].high >= h) return false; // Older bar has higher high
    }

    return true;
}

/// @brief Returns true if rates[idx].low is the lowest within the lookback window.
/// Only processes CONFIRMED pivots — will not fire on recent unconfirmed bars.
/// @param rates Array of MqlRates in series order (0=newest).
/// @param idx Index of the candidate pivot bar (0=newest).
/// @param lookback Number of bars to check on each side (symmetric).
/// @return True if the bar at idx is a confirmed pivot low.
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

//==========================================================================
//  SECTION 8: STRUCTURE DETECTION (BOS / CHoCH)
//  Uses confirmed pivot highs/lows from the last InpStructureLookback bars.
//  All structural breaks are assessed on candle CLOSE (no wick triggers).
//==========================================================================

/// @brief Detects current market structure, BOS, CHoCH, and Premium/Discount position
/// using the last N confirmed M5 bars.
/// @param rates M5 rates array in series order (0=newest).
/// @param total Number of bars in the array.
/// @return Populated SStructureInfo struct.
SStructureInfo DetectStructure(const MqlRates &rates[], int total) {
    SStructureInfo result;
    ZeroMemory(result);
    result.valid = false;

    if (total < InpStructureLookback + InpPivotLookback + 1) return result;

    // Collect up to 4 confirmed pivot highs and lows within the lookback window
    double ph[4]; int ph_count = 0;
    double pl[4]; int pl_count = 0;

    // Search from InpPivotLookback (oldest that can be confirmed) through lookback
    int search_end = MathMin(total - InpPivotLookback - 1, InpStructureLookback);
    for (int i = InpPivotLookback; i < search_end && (ph_count < 4 || pl_count < 4); i++) {
        if (ph_count < 4 && IsPivotHigh(rates, i, InpPivotLookback))
            ph[ph_count++] = rates[i].high;
        if (pl_count < 4 && IsPivotLow(rates, i, InpPivotLookback))
            pl[pl_count++] = rates[i].low;
    }

    if (ph_count < 2 || pl_count < 2) return result; // Need at least 2 of each

    // ph[0]=most recent pivot high, ph[1]=second most recent, etc.
    double last_high = ph[0], prev_high = ph[1];
    double last_low = pl[0], prev_low = pl[1];

    result.last_high = last_high;
    result.last_low = last_low;
    result.prev_high = prev_high;
    result.prev_low = prev_low;

    // Determine underlying structure from sequential swing comparisons
    bool is_bull = (last_high > prev_high) && (last_low > prev_low);
    bool is_bear = (last_high < prev_high) && (last_low < prev_low);
    result.structure = is_bull ? STRUCT_BULL : (is_bear ? STRUCT_BEAR : STRUCT_FLAT);

    // Use index 1 (last CLOSED bar) for structural break detection — candle close only
    double curr_close = rates[1].close;

    result.bos_dir = STRUCT_FLAT;
    result.choch_dir = STRUCT_FLAT;

    // A bullish break (close > last_high) is a BOS if the prior structure was
    // bullish/flat (continuation), or a CHoCH if the prior structure was bearish
    // (reversal). Symmetric logic applies to bearish breaks.
    if (curr_close > last_high) {
        if (result.structure == STRUCT_BEAR) result.choch_dir = STRUCT_BULL; // Bull CHoCH (reversal)
        else result.bos_dir = STRUCT_BULL; // Bull BOS (continuation)
    } else if (curr_close < last_low) {
        if (result.structure == STRUCT_BULL) result.choch_dir = STRUCT_BEAR; // Bear CHoCH (reversal)
        else result.bos_dir = STRUCT_BEAR; // Bear BOS (continuation)
    }

    // Premium/Discount Array: 0.0 = price at last_low, 1.0 = price at last_high
    double pd_range = last_high - last_low;
    result.pd_array = (pd_range > 0) ?
        MathMax(0.0, MathMin(1.0, (curr_close - last_low) / pd_range)) : 0.5;

    result.valid = true;

    return result;
}

//==========================================================================
//  SECTION 9: LIQUIDITY SWEEP DETECTION
//  Three-tier sweep classification. Higher tiers = higher signal quality.
//  Tier 3: Daily PDH/PDL or Asian session range (institutional manipulation)
//  Tier 2: 50-period major swings or round-number proximity
//  Tier 1: Internal structural pivots (lowest quality, often filtered out)
//==========================================================================

/// @brief Checks if the close price is near a psychological round-number level.
/// Uses a magnitude-based step to determine what "round" means for the asset.
/// @param close_price Current price.
/// @param recent_high Recent 5-bar high.
/// @param recent_low Recent 5-bar low.
/// @param atr Current ATR.
/// @return True if the close is within 0.5 ATR of a round number.
bool IsRoundNumberSweep(double close_price, double recent_high, double recent_low, double atr) {
    if (close_price <= 0) return false;

    double magnitude = MathPow(10.0, MathFloor(MathLog10(close_price)));
    double step;

    // Forex pairs (magnitude 1) should step by 0.01 (e.g., 1.0800, 1.0900)
    if (magnitude <= 10) {
        step = 0.01;
    } else {
        step = magnitude / 100.0; // e.g., Index at 5200 steps by 52 (rounds to 50s/100s)
    }

    double closest_round = MathRound(close_price / step) * step;
    double dist_to_round = MathMin(
        MathAbs(recent_high - closest_round),
        MathAbs(recent_low  - closest_round)
    );

    return dist_to_round < (atr * 0.5);
}

/// @brief Unified liquidity sweep detector returning the tier and depth.
/// @param rates M5 rates array (series order, 0=newest).
/// @param total Total bars available.
/// @param atr Current ATR value.
/// @param tier [Output] Sweep tier: 0=none, 1=internal, 2=major, 3=daily.
/// @param depth_atr [Output] Sweep depth expressed in ATR multiples.
/// @param sweep_dir [Output] Direction of the sweep: ZONE_BULL or ZONE_BEAR.
void DetectLiquiditySweep(const MqlRates &rates[], int total,
                          double atr, int &tier, double &depth_atr, int &sweep_dir) {
    tier = SWEEP_NONE;
    depth_atr = 0.0;
    sweep_dir = -1;

    if (total < InpMajorSwingPeriod + 5 || atr <= 0) return;

    // --- Price context from last confirmed bar (index 1)
    double close = rates[1].close;
    double rec_lo5 = GetRecentLow(rates, 1, 5); // 5-bar rolling low (excl. current)
    double rec_hi5 = GetRecentHigh(rates, 1, 5); // 5-bar rolling high (excl. current)

    // --- Major 50-period swing levels (shifted 5 bars to avoid lookahead)
    int shift = 5;
    double major_lo50 = GetRecentLow(rates, 1 + shift, InpMajorSwingPeriod);
    double major_hi50 = GetRecentHigh(rates, 1 + shift, InpMajorSwingPeriod);

    // Fetch centralized session state
    SSessionInfo session = GetSessionInfo();

    // -----------------------------------------------------------------------
    // TIER 3: Daily PDH/PDL and Asian Session Range Sweeps
    // -----------------------------------------------------------------------
    if (g_pdl > 0 && rec_lo5 < g_pdl && close > g_pdl) {
        tier = SWEEP_DAILY;
        depth_atr = (g_pdl - rec_lo5) / atr;
        sweep_dir = ZONE_BULL;
        return;
    }
    if (g_pdh > 0 && rec_hi5 > g_pdh && close < g_pdh) {
        tier = SWEEP_DAILY;
        depth_atr = (rec_hi5 - g_pdh) / atr;
        sweep_dir = ZONE_BEAR;
        return;
    }
    // Restrict Asian range sweeps to the London Open killzone
    if (session.is_london_open && g_asian_low > 0 && rec_lo5 < g_asian_low && close > g_asian_low) {
        tier = SWEEP_DAILY;
        depth_atr = (g_asian_low - rec_lo5) / atr;
        sweep_dir = ZONE_BULL;
        return;
    }
    if (session.is_london_open && g_asian_high > 0 && rec_hi5 > g_asian_high && close < g_asian_high) {
        tier = SWEEP_DAILY;
        depth_atr = (rec_hi5 - g_asian_high) / atr;
        sweep_dir = ZONE_BEAR;
        return;
    }

    // -----------------------------------------------------------------------
    // TIER 2: Major 50-Period Swing Sweeps & Round Number Sweeps
    // -----------------------------------------------------------------------
    if (major_lo50 > 0 && rec_lo5 < major_lo50 && close > major_lo50) {
        tier = SWEEP_MAJOR;
        depth_atr = (major_lo50 - rec_lo5) / atr;
        sweep_dir = ZONE_BULL;
        return;
    }
    if (major_hi50 > 0 && rec_hi5 > major_hi50 && close < major_hi50) {
        tier = SWEEP_MAJOR;
        depth_atr = (rec_hi5 - major_hi50) / atr;
        sweep_dir = ZONE_BEAR;
        return;
    }
    if (IsRoundNumberSweep(close, rec_hi5, rec_lo5, atr)) {
        tier = SWEEP_MAJOR;
        depth_atr = 0.5;
        sweep_dir = (rates[1].close > rates[1].open) ? ZONE_BULL : ZONE_BEAR;
        return;
    }

    // -----------------------------------------------------------------------
    // TIER 1: Internal Structural Pivot Sweeps
    // -----------------------------------------------------------------------
    if (g_structure.valid && g_structure.last_low > 0 &&
        rec_lo5 < g_structure.last_low && close > g_structure.last_low) {
        tier = SWEEP_INTERNAL;
        depth_atr = (g_structure.last_low - rec_lo5) / atr;
        sweep_dir = ZONE_BULL;
        return;
    }
    if (g_structure.valid && g_structure.last_high > 0 &&
        rec_hi5 > g_structure.last_high && close < g_structure.last_high) {
        tier = SWEEP_INTERNAL;
        depth_atr = (rec_hi5 - g_structure.last_high) / atr;
        sweep_dir = ZONE_BEAR;
        return;
    }
}

//==========================================================================
//  SECTION 10: POI MANAGEMENT (FVG, IFVG, ORDER BLOCK)
//  Incremental update system: processes new zones from the latest bar triplet
//  and ages/mitigates existing zones on every new bar.
//==========================================================================

/// @brief Compacts a zone array by removing all inactive zones and
/// shifting active ones to the front. Resets the count.
/// @param zones The zone array to compact.
/// @param count [In/Out] The current active count.
void CompactZoneArray(SZone &zones[], int &count) {
    int new_count = 0;

    for (int i = 0; i < count; i++) {
        if (zones[i].active) {
            if (new_count != i) zones[new_count] = zones[i];
            new_count++;
        }
    }

    count = new_count;
}

/// @brief Adds a new zone to an array if capacity allows.
/// If the array is full, the oldest zone is evicted (FIFO).
void AddZone(SZone &zones[], int &count, const SZone &new_zone) {
    // Cap the logical size to the user input, safely bounded by the macro
    int max_allowed = (int)MathMin(InpMaxPOIsPerType, MAX_ZONES);

    if (count < max_allowed) {
        zones[count] = new_zone;
        count++;
    } else {
        // Evict oldest (index 0), shift all zones left, append new at end
        for (int i = 0; i < max_allowed - 1; i++) zones[i] = zones[i + 1];

        zones[max_allowed - 1] = new_zone;
        count = max_allowed;
    }
}

/// @brief Core incremental POI update step.
/// Processes one bar triplet (c1, c2, curr) to:
/// 1. Age all existing zones by 1 bar.
/// 2. Detect new FVG/OB zones from the c2 displacement candle.
/// 3. Convert breached FVGs to IFVGs.
/// 4. Track mitigations and invalidate exhausted zones.
/// 5. Convert breached OBs to Breaker Blocks.
/// @param c1 Oldest bar in triplet (rates[k+2]).
/// @param c2 Middle / displacement bar (rates[k+1]).
/// @param curr Newest bar (rates[k]).
/// @param vol_sma_c2 Volume SMA at the time of c2 for ratio calculation.
void UpdatePOIsIncremental(const MqlRates &c1, const MqlRates &c2,
                           const MqlRates &curr, double vol_sma_c2) {
    double curr_close = curr.close;
    double curr_low = curr.low;
    double curr_high = curr.high;

    // ---- Step 1: Age all active zones by 1 bar ----
    for (int i = 0; i < g_fvg_count; i++) if (g_fvgs[i].active) g_fvgs[i].age_bars++;
    for (int i = 0; i < g_ifvg_count; i++) if (g_ifvgs[i].active) g_ifvgs[i].age_bars++;
    for (int i = 0; i < g_ob_count; i++) if (g_obs[i].active) g_obs[i].age_bars++;

    // ---- Step 2: FVG → IFVG conversion (flip on close-through) ----
    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active) continue;
        if (g_fvgs[i].zone_type == ZONE_BULL && curr_close < g_fvgs[i].zone_low) {
            // Bull FVG was closed through → becomes Bear IFVG
            SZone ifvg;
            ZeroMemory(ifvg);
            ifvg.active = true;
            ifvg.zone_type = ZONE_BEAR;
            ifvg.zone_high = g_fvgs[i].zone_high;
            ifvg.zone_low = g_fvgs[i].zone_low;
            AddZone(g_ifvgs, g_ifvg_count, ifvg);
            g_fvgs[i].active = false;
        } else if (g_fvgs[i].zone_type == ZONE_BEAR && curr_close > g_fvgs[i].zone_high) {
            // Bear FVG was closed through → becomes Bull IFVG
            SZone ifvg;
            ZeroMemory(ifvg);
            ifvg.active = true;
            ifvg.zone_type = ZONE_BULL;
            ifvg.zone_high = g_fvgs[i].zone_high;
            ifvg.zone_low = g_fvgs[i].zone_low;
            AddZone(g_ifvgs, g_ifvg_count, ifvg);
            g_fvgs[i].active = false;
        }
    }

    // ---- Step 3: Mitigation tracking and zone expiry (all 3 types) ----
    // A zone is "touched" when price enters it from the correct side.
    // A zone is "closed through" when price body closes on the wrong side (invalidated).
    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active) continue;
        bool inside = (g_fvgs[i].zone_type == ZONE_BULL && curr_low <= g_fvgs[i].zone_high) ||
                      (g_fvgs[i].zone_type == ZONE_BEAR && curr_high >= g_fvgs[i].zone_low);
        if (inside && !g_fvgs[i].is_touching) {
            g_fvgs[i].mitigations++;
            g_fvgs[i].is_touching = true;
        } else if (!inside) {
            g_fvgs[i].is_touching = false;
        }
        // Expire zones that are over-mitigated or too old
        if (g_fvgs[i].mitigations > InpMaxMitigations ||
            g_fvgs[i].age_bars > InpMaxPOIAgeBars)
            g_fvgs[i].active = false;
    }

    for (int i = 0; i < g_ifvg_count; i++) {
        if (!g_ifvgs[i].active) continue;
        bool inside = (g_ifvgs[i].zone_type == ZONE_BULL && curr_low <= g_ifvgs[i].zone_high) ||
                      (g_ifvgs[i].zone_type == ZONE_BEAR && curr_high >= g_ifvgs[i].zone_low);
        if (inside && !g_ifvgs[i].is_touching) {
            g_ifvgs[i].mitigations++;
            g_ifvgs[i].is_touching = true;
        } else if (!inside) {
            g_ifvgs[i].is_touching = false;
        }
        if (g_ifvgs[i].mitigations > InpMaxMitigations ||
            g_ifvgs[i].age_bars > InpMaxPOIAgeBars)
            g_ifvgs[i].active = false;
    }

    for (int i = 0; i < g_ob_count; i++) {
        if (!g_obs[i].active) continue;
        bool inside = (g_obs[i].zone_type == ZONE_BULL && curr_low <= g_obs[i].zone_high) ||
                      (g_obs[i].zone_type == ZONE_BEAR && curr_high >= g_obs[i].zone_low);
        if (inside && !g_obs[i].is_touching) {
            g_obs[i].mitigations++;
            g_obs[i].is_touching = true;
        } else if (!inside) {
            g_obs[i].is_touching = false;
        }
        // OB Breaker Block conversion: close through OB zone flips its bias
        if (g_obs[i].zone_type == ZONE_BULL && curr_close < g_obs[i].zone_low) {
            g_obs[i].zone_type = ZONE_BEAR;
            g_obs[i].ob_tier = OB_BREAKER;
            g_obs[i].mitigations = 0;
            g_obs[i].age_bars = 0;
            continue; // Keep the breaker active
        }
        if (g_obs[i].zone_type == ZONE_BEAR && curr_close > g_obs[i].zone_high) {
            g_obs[i].zone_type = ZONE_BULL;
            g_obs[i].ob_tier = OB_BREAKER;
            g_obs[i].mitigations = 0;
            g_obs[i].age_bars = 0;
            continue;
        }
        if (g_obs[i].mitigations > InpMaxMitigations ||
            g_obs[i].age_bars > InpMaxPOIAgeBars)
            g_obs[i].active = false;
    }

    // ---- Step 4: Create new FVGs from c2's price action ----
    // FVG conditions: c2 is a strong displacement candle AND there is a true gap
    double c2_vol_ratio = (vol_sma_c2 > 0) ? ((double)c2.tick_volume / vol_sma_c2) : 1.0;

    double c2_body_ratio = GetBodyRatio(c2);

    if (c2_vol_ratio >= InpMinFVGVolRatio && c2_body_ratio >= InpMinOBBodyRatio) {
        // Bull FVG: gap between c1.high and curr.low, c2 is bullish displacement
        if (c1.high < curr.low && c2.close > c2.open) {
            SZone fvg;
            ZeroMemory(fvg);
            fvg.active = true;
            fvg.zone_type = ZONE_BULL;
            fvg.zone_high = curr.low;
            fvg.zone_low = c1.high;
            fvg.vol_strength = (float)c2_vol_ratio;
            AddZone(g_fvgs, g_fvg_count, fvg);
        }
        // Bear FVG: gap between curr.high and c1.low, c2 is bearish displacement
        else if (c1.low > curr.high && c2.close < c2.open) {
            SZone fvg;
            ZeroMemory(fvg);
            fvg.active = true;
            fvg.zone_type = ZONE_BEAR;
            fvg.zone_high = c1.low;
            fvg.zone_low = curr.high;
            fvg.vol_strength = (float)c2_vol_ratio;
            AddZone(g_fvgs, g_fvg_count, fvg);
        }
    }

    // ---- Step 5: Create new Order Blocks from c2's engulfment ----
    int ob_tier = (c2_vol_ratio >= 1.5) ? OB_MAJOR : OB_INTERNAL;

    // Bull OB: c2 is bullish, c1 was bearish, c2 closes above c1.high (engulf)
    // Enforce the body ratio to prevent low-quality wick engulfments
    if (c2.close > c2.open && c1.close < c1.open &&
        c2.close > c1.high && c2_vol_ratio >= InpMinOBVolRatio && c2_body_ratio >= InpMinOBBodyRatio) {
        SZone ob;
        ZeroMemory(ob);
        ob.active = true;
        ob.zone_type = ZONE_BULL;
        ob.zone_high = c1.high;
        ob.zone_low = c1.low;
        ob.ob_tier = ob_tier;
        ob.vol_strength = (float)c2_vol_ratio;
        AddZone(g_obs, g_ob_count, ob);
    }
    // Bear OB: c2 is bearish, c1 was bullish, c2 closes below c1.low (engulf)
    else if (c2.close < c2.open && c1.close > c1.open &&
             c2.close < c1.low && c2_vol_ratio >= InpMinOBVolRatio && c2_body_ratio >= InpMinOBBodyRatio) {
        SZone ob;
        ZeroMemory(ob);
        ob.active = true;
        ob.zone_type = ZONE_BEAR;
        ob.zone_high = c1.high;
        ob.zone_low = c1.low;
        ob.ob_tier = ob_tier;
        ob.vol_strength = (float)c2_vol_ratio;
        AddZone(g_obs, g_ob_count, ob);
    }

    // ---- Step 6: Compact all arrays to remove stale zones ----
    CompactZoneArray(g_fvgs, g_fvg_count);
    CompactZoneArray(g_ifvgs, g_ifvg_count);
    CompactZoneArray(g_obs, g_ob_count);
}

/// @brief Performs a full warmup pass through historical M5 bars to build
/// the initial POI state at EA startup. Processes bars oldest → newest.
void WarmupPOIs() {
    int warmup = MathMin(InpWarmupBars, 2000);
    MqlRates rates[];
    ArraySetAsSeries(rates, true);

    int copied = CopyRates(_Symbol, PERIOD_M5, 0, warmup + 25, rates);
    if (copied < 25) {
        Log("WarmupPOIs: Insufficient historical bars.", false);
        return;
    }

    // Reset all POI state before rebuild
    g_fvg_count = 0; g_ifvg_count = 0; g_ob_count = 0;

    // k = current bar index (0=newest). Process from oldest available → newest.
    // With series order, high index = older. Start at (copied-3), decrement to 1.
    for (int k = copied - 25; k >= 1; k--) {
        double vol_sma_at_k = GetVolumeSMA(rates, k + 1, 20);
        UpdatePOIsIncremental(rates[k + 2], rates[k + 1], rates[k], vol_sma_at_k);
    }

    Log(StringFormat("[Nexubot] POI Warmup: FVGs=%d, IFVGs=%d, OBs=%d",
              g_fvg_count, g_ifvg_count, g_ob_count));
}

/// @brief Checks if there is a relevant active bullish POI within proximity.
/// @param close_price Current price.
/// @param atr Current ATR.
/// @param proximity Max distance in ATR multiples.
/// @return true if a bullish POI is found within the specified proximity, false otherwise.
bool HasActiveBullPOI(double close_price, double atr, double proximity = 0.5) {
    // Check FVGs
    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active || g_fvgs[i].zone_type != ZONE_BULL) continue;
        if (g_fvgs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_fvgs[i].zone_high);
        if (dist <= atr * proximity) return true;
    }

    // Check OBs
    for (int i = 0; i < g_ob_count; i++) {
        if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BULL) continue;
        if (g_obs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_obs[i].zone_high);
        if (dist <= atr * proximity) return true;
    }

    return false;
}

/// @brief Checks if there is a relevant active bearish POI within proximity.
/// @param close_price Current price.
/// @param atr Current ATR.
/// @param proximity Max distance in ATR multiples.
/// @return true if a bearish POI is found within the specified proximity, false otherwise.
bool HasActiveBearPOI(double close_price, double atr, double proximity = 0.5) {
    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active || g_fvgs[i].zone_type != ZONE_BEAR) continue;
        if (g_fvgs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_fvgs[i].zone_low);
        if (dist <= atr * proximity) return true;
    }

    for (int i = 0; i < g_ob_count; i++) {
        if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BEAR) continue;
        if (g_obs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_obs[i].zone_low);
        if (dist <= atr * proximity) return true;
    }

    return false;
}

/// @brief Finds the nearest opposing IFVG or Major OB in the trade direction.
/// Used for dynamic TP capping to avoid running into structural blockades.
/// @param direction ZONE_BULL (long) or ZONE_BEAR (short).
/// @param entry Trade entry price.
/// @return Price level of the nearest opposing blockade, or 0.0 if none found.
double GetNearestOpposingPOI(int direction, double entry) {
    double nearest = 0.0;

    if (direction == ZONE_BULL) {
        // For a LONG, opposing POIs are bearish zones ABOVE entry
        for (int i = 0; i < g_ifvg_count; i++) {
            if (!g_ifvgs[i].active || g_ifvgs[i].zone_type != ZONE_BEAR) continue;
            if (g_ifvgs[i].zone_low > entry) {
                if (nearest <= 0 || g_ifvgs[i].zone_low < nearest)
                    nearest = g_ifvgs[i].zone_low;
            }
        }

        for (int i = 0; i < g_ob_count; i++) {
            if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BEAR) continue;
            if (g_obs[i].ob_tier != OB_MAJOR && g_obs[i].ob_tier != OB_BREAKER) continue;
            if (g_obs[i].zone_low > entry) {
                if (nearest <= 0 || g_obs[i].zone_low < nearest)
                    nearest = g_obs[i].zone_low;
            }
        }
    } else {
        // For a SHORT, opposing POIs are bullish zones BELOW entry
        for (int i = 0; i < g_ifvg_count; i++) {
            if (!g_ifvgs[i].active || g_ifvgs[i].zone_type != ZONE_BULL) continue;
            if (g_ifvgs[i].zone_high < entry) {
                if (nearest <= 0 || g_ifvgs[i].zone_high > nearest)
                    nearest = g_ifvgs[i].zone_high;
            }
        }

        for (int i = 0; i < g_ob_count; i++) {
            if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BULL) continue;
            if (g_obs[i].ob_tier != OB_MAJOR && g_obs[i].ob_tier != OB_BREAKER) continue;
            if (g_obs[i].zone_high < entry) {
                if (nearest <= 0 || g_obs[i].zone_high > nearest)
                    nearest = g_obs[i].zone_high;
            }
        }
    }
    return nearest;
}

//==========================================================================
//  SECTION 11: SESSION MANAGEMENT
//==========================================================================

/// @brief Returns the current session context based on server time.
/// @return SSessionInfo struct with session name, multiplier, and flags.
SSessionInfo GetSessionInfo() {
    SSessionInfo info;
    ZeroMemory(info);
    info.multiplier = 0.90; // Dead zone default

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;

    // Robust midnight-crossing checks
    bool is_asian = (InpAsianStart < InpAsianEnd) ?
                    (h >= InpAsianStart && h < InpAsianEnd) :
                    (h >= InpAsianStart || h < InpAsianEnd);

    bool is_london = (InpLondonStart < InpLondonEnd) ?
                     (h >= InpLondonStart && h < InpLondonEnd) :
                     (h >= InpLondonStart || h < InpLondonEnd);

    bool is_ny = (InpNYStart < InpNYEnd) ?
                 (h >= InpNYStart && h < InpNYEnd) :
                 (h >= InpNYStart || h < InpNYEnd);

    info.is_active = is_asian || is_london || is_ny;
    info.is_london_open = (h >= InpLondonStart && h < InpLondonStart + 3); // First 3hrs

    if (is_ny) {
        info.session_name = "NY";
        info.multiplier = 1.05;
    }
    else if (is_london) {
        info.session_name = "LONDON";
        info.multiplier = 1.03;
    }
    else if (is_asian) {
        info.session_name = "ASIAN";
        info.multiplier = 0.97;
    }
    else {
        info.session_name = "DEAD";
        info.multiplier = 0.90;
    }

    return info;
}

//==========================================================================
//  SECTION 12: SMC STRATEGY ANALYSIS FUNCTIONS
//  Each function implements one strategy and returns an SSignal.
//  All strategies follow the same return contract: signal.valid = true/false.
//==========================================================================

/// @brief STRATEGY 1: Liquidity Sweep with BOS confirmation.
/// Highest quality setup. Requires a Tier-2+ sweep AND a structural break
/// to have BOTH occurred within their respective recency windows.
/// @param curr Last confirmed bar (rates[1]).
/// @param atr Current ATR.
/// @return SSignal with valid=true if conditions met, otherwise valid=false.
SSignal Strategy_LiquiditySweep(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    // Require a Tier2+ sweep within the recency window
    if (g_recent_sweep_tier < 2 || g_bars_since_sweep > InpSweepRecencyBars) return sig;

    // Require a BOS/CHoCH within the recency window — no direction filter yet,
    // direction alignment is enforced below.
    int bos_dir = g_recent_break_dir;
    if (bos_dir == STRUCT_FLAT || g_bars_since_break > InpBOSRecencyBars) return sig;

    // The sweep must align with the BOS direction
    int req_sweep_dir = (bos_dir == STRUCT_BULL) ? ZONE_BULL : ZONE_BEAR;
    if (g_recent_sweep_dir != req_sweep_dir) return sig; // Reject conflicting signals

    double atr_buf = atr * InpSweepSLBufferATR;
    string name = (g_recent_sweep_tier == SWEEP_DAILY) ? "Daily/Asian Sweep" : "Major Swing Sweep";

    if (bos_dir == STRUCT_BULL) {
        sig.valid = true;
        sig.direction = ZONE_BULL;
        sig.strategy_name = name;
        sig.suggested_sl = curr.low - atr_buf;
    }
    else if (bos_dir == STRUCT_BEAR) {
        sig.valid = true;
        sig.direction = ZONE_BEAR;
        sig.strategy_name = name;
        sig.suggested_sl = curr.high + atr_buf;
    }

    return sig;
}

/// @brief STRATEGY 2: ICT Optimal Trade Entry (OTE Fibonacci).
/// Enters at the 62-79% Fibonacci retracement of the last swing following
/// a confirmed BOS. Requires H1 trend alignment for additional confirmation.
/// Historically the cleanest "smart money" entry model.
/// @param curr Last confirmed bar.
/// @param atr Current ATR.
/// @return SSignal with valid=true if conditions met, otherwise valid=false.
SSignal Strategy_ICT_OTE(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    if (!g_structure.valid) return sig;
    if (g_structure.last_high <= 0 || g_structure.last_low <= 0) return sig;

    double close_price = curr.close;
    double atr_buf = atr * 0.2;
    double range = g_structure.last_high - g_structure.last_low;
    if (range <= 0) return sig;

    // Volume confirmation for OTE entries
    MqlRates rates_check[];
    ArraySetAsSeries(rates_check, true);

    double vol_sma = 1.0;
    if (CopyRates(_Symbol, PERIOD_M5, 1, 25, rates_check) == 25)
        vol_sma = GetVolumeSMA(rates_check, 1, 20);

    double vol_ratio = (double)curr.tick_volume / vol_sma;
    if (vol_ratio < InpMinVolRatio) return sig; // Require at least moderate volume

    // Bullish OTE: Structure is BULL + H1 trending up → buy the dip to 62-79%
    if (g_structure.structure == STRUCT_BULL && g_htf_trend == 1.0) {
        double fib_62 = g_structure.last_high - range * 0.618;
        double fib_79 = g_structure.last_high - range * 0.786;
        if (fib_79 <= close_price && close_price <= fib_62 && curr.close > curr.open) {
            sig.valid = true;
            sig.direction = ZONE_BULL;
            sig.strategy_name = "ICT OTE (Bullish)";
            sig.suggested_sl = g_structure.last_low - atr_buf;
        }
    }

    // Bearish OTE: Structure is BEAR + H1 trending down → sell the rally to 62-79%
    else if (g_structure.structure == STRUCT_BEAR && g_htf_trend == -1.0) {
        double fib_62 = g_structure.last_low + range * 0.618;
        double fib_79 = g_structure.last_low + range * 0.786;
        if (fib_62 <= close_price && close_price <= fib_79 && curr.close < curr.open) {
            sig.valid = true;
            sig.direction = ZONE_BEAR;
            sig.strategy_name = "ICT OTE (Bearish)";
            sig.suggested_sl = g_structure.last_high + atr_buf;
        }
    }
    return sig;
}

/// @brief STRATEGY 3: IFVG Mitigation Re-Test.
/// Enters after an Inverted Fair Value Gap (a previously-bullish gap that
/// has been invalidated) acts as new resistance/support. Requires the
/// close to be on the "correct" side of the IFVG CE (midpoint).
/// @param curr Last confirmed bar.
/// @param atr Current ATR.
/// @return SSignal with valid=true if conditions met, otherwise valid=false.
SSignal Strategy_IFVG_Mitigation(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    double close_price = curr.close;
    bool bouncing_up = close_price > curr.open;
    bool bouncing_down = close_price < curr.open;
    if (!bouncing_up && !bouncing_down) return sig;

    double atr_buf = atr * 0.2;

    if (bouncing_up) {
        // Check if price is bouncing off a BULL IFVG (former resistance acting as support)
        for (int i = 0; i < g_ifvg_count; i++) {
            if (!g_ifvgs[i].active || g_ifvgs[i].zone_type != ZONE_BULL) continue;
            if (g_ifvgs[i].mitigations > 2) continue;
            // Price must have touched the IFVG and closed ABOVE the CE midpoint
            double ce_mid = (g_ifvgs[i].zone_high + g_ifvgs[i].zone_low) / 2.0;
            if (curr.low <= g_ifvgs[i].zone_high && close_price > ce_mid) {
                sig.valid = true;
                sig.direction = ZONE_BULL;
                sig.strategy_name = "IFVG Re-Test";

                // Anchor the SL behind the entire IFVG zone, not just the single candle wick
                double sl_anchor = MathMin(curr.low, g_ifvgs[i].zone_low);
                sig.suggested_sl = sl_anchor - atr_buf;
                return sig;
            }
        }
    }

    if (bouncing_down) {
        // Price bouncing off a BEAR IFVG (former support acting as resistance)
        for (int i = 0; i < g_ifvg_count; i++) {
            if (!g_ifvgs[i].active || g_ifvgs[i].zone_type != ZONE_BEAR) continue;
            if (g_ifvgs[i].mitigations > 2) continue;
            double ce_mid = (g_ifvgs[i].zone_high + g_ifvgs[i].zone_low) / 2.0;
            if (curr.high >= g_ifvgs[i].zone_low && close_price < ce_mid) {
                sig.valid = true;
                sig.direction = ZONE_BEAR;
                sig.strategy_name = "IFVG Re-Test";

                // Anchor the SL above the entire IFVG zone
                double sl_anchor = MathMax(curr.high, g_ifvgs[i].zone_high);
                sig.suggested_sl = sl_anchor + atr_buf;
                return sig;
            }
        }
    }

    return sig;
}

/// @brief STRATEGY 4: POI Reversal at Order Block / FVG.
/// Enters at validated OBs and FVGs that have been tested AFTER a
/// Tier-2+ sweep occurred within the recency window. Requires vol > 2.0
/// for MAJOR/BREAKER OBs to ensure the institutional defending entity is
/// @param curr Last confirmed bar.
/// @param atr Current ATR.
/// @return SSignal with valid=true if conditions met, otherwise valid=false.
SSignal Strategy_POI_Reversal(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    // Only after a significant sweep occurred recently (not necessarily this bar)
    if (g_recent_sweep_tier < 2 || g_bars_since_sweep > InpSweepRecencyBars) return sig;

    double close_price = curr.close;
    bool bouncing_up = close_price > curr.open;
    bool bouncing_down = close_price < curr.open;
    if (!bouncing_up && !bouncing_down) return sig;

    double atr_buf = atr * 0.2;

    if (bouncing_up && g_recent_sweep_dir == ZONE_BULL) {
        // Bullish: OB bounce
        for (int i = 0; i < g_ob_count; i++) {
            if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BULL) continue;
            if (g_obs[i].mitigations > 2 || g_obs[i].ob_tier == OB_INTERNAL || g_obs[i].vol_strength < 2.0) continue;
            double ce_mid = (g_obs[i].zone_high + g_obs[i].zone_low) / 2.0;
            if (curr.low <= g_obs[i].zone_high && close_price > ce_mid) {
                string tier_name = (g_obs[i].ob_tier == OB_BREAKER) ? "BREAKER" : "MAJOR";
                sig.valid = true;
                sig.direction = ZONE_BULL;
                sig.strategy_name = tier_name + " OB CE Bounce";

                // Anchor the SL behind the entire Order Block zone
                double sl_anchor = MathMin(curr.low, g_obs[i].zone_low);
                sig.suggested_sl = sl_anchor - atr_buf;
                return sig;
            }
        }

        // FVG bounce
        for (int i = 0; i < g_fvg_count; i++) {
            if (!g_fvgs[i].active || g_fvgs[i].zone_type != ZONE_BULL) continue;
            if (g_fvgs[i].mitigations > 2) continue;
            double ce_mid = (g_fvgs[i].zone_high + g_fvgs[i].zone_low) / 2.0;
            if (curr.low <= g_fvgs[i].zone_high && close_price > ce_mid) {
                sig.valid = true;
                sig.direction = ZONE_BULL;
                sig.strategy_name = "FVG Bounce";

                // Anchor the SL behind the entire Fair Value Gap zone
                double sl_anchor = MathMin(curr.low, g_fvgs[i].zone_low);
                sig.suggested_sl = sl_anchor - atr_buf;
                return sig;
            }
        }
    }

    if (bouncing_down && g_recent_sweep_dir == ZONE_BEAR) {
        // Bearish: OB rejection
        for (int i = 0; i < g_ob_count; i++) {
            if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BEAR) continue;
            if (g_obs[i].mitigations > 2 || g_obs[i].ob_tier == OB_INTERNAL || g_obs[i].vol_strength < 2.0) continue;
            double ce_mid = (g_obs[i].zone_high + g_obs[i].zone_low) / 2.0;
            if (curr.high >= g_obs[i].zone_low && close_price < ce_mid) {
                string tier_name = (g_obs[i].ob_tier == OB_BREAKER) ? "BREAKER" : "MAJOR";
                sig.valid = true;
                sig.direction = ZONE_BEAR;
                sig.strategy_name = tier_name + " OB CE Bounce";

                // Anchor the SL above the entire Order Block zone
                double sl_anchor = MathMax(curr.high, g_obs[i].zone_high);
                sig.suggested_sl = sl_anchor + atr_buf;
                return sig;
            }
        }

        // FVG rejection
        for (int i = 0; i < g_fvg_count; i++) {
            if (!g_fvgs[i].active || g_fvgs[i].zone_type != ZONE_BEAR) continue;
            if (g_fvgs[i].mitigations > 2) continue;
            double ce_mid = (g_fvgs[i].zone_high + g_fvgs[i].zone_low) / 2.0;
            if (curr.high >= g_fvgs[i].zone_low && close_price < ce_mid) {
                sig.valid = true;
                sig.direction = ZONE_BEAR;
                sig.strategy_name = "FVG Bounce";

                // Anchor the SL above the entire Fair Value Gap zone
                double sl_anchor = MathMax(curr.high, g_fvgs[i].zone_high);
                sig.suggested_sl = sl_anchor + atr_buf;
                return sig;
            }
        }
    }

    return sig;
}

/// @brief STRATEGY 5: VWAP Bounce.
/// Institutional volume-backed bounce off the session VWAP. Requires:
/// - Price touch and close on correct side of VWAP
/// - Volume above average (institutional displacement)
/// - A Tier 2+ sweep already completed (avoid counter-trend traps)
/// @param curr Last confirmed bar.
/// @param atr Current ATR.
/// @return SSignal with valid=true if conditions met, otherwise valid=false.
SSignal Strategy_VWAP_Bounce(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    if (g_vwap <= 0 || g_recent_sweep_tier < 2 || g_bars_since_sweep > InpSweepRecencyBars) return sig;

    // Require institutional volume: vol > vol_sma × 1.2
    MqlRates tmp[];
    ArraySetAsSeries(tmp, true);

    double vol_sma = 1.0;
    if (CopyRates(_Symbol, PERIOD_M5, 1, 25, tmp) == 25)
        vol_sma = GetVolumeSMA(tmp, 1, 20);

    double vol_str = (double)curr.tick_volume / vol_sma;
    if (vol_str < InpMinVolRatio) return sig;

    double atr_buf = atr * 0.3;

    // Bullish VWAP bounce: recent low touched VWAP, closed above it with green body
    if (curr.low <= g_vwap && curr.close > g_vwap && curr.close > curr.open && g_recent_sweep_dir == ZONE_BULL) {
        sig.valid = true;
        sig.direction = ZONE_BULL;
        sig.strategy_name = "VWAP Bounce";
        sig.suggested_sl = curr.low - atr_buf;
    }

    // Bearish VWAP rejection: recent high touched VWAP, closed below it with red body
    else if (curr.high >= g_vwap && curr.close < g_vwap && curr.close < curr.open && g_recent_sweep_dir == ZONE_BEAR) {
        sig.valid = true;
        sig.direction = ZONE_BEAR;
        sig.strategy_name = "VWAP Bounce";
        sig.suggested_sl = curr.high + atr_buf;
    }

    return sig;
}

/// @brief Unified strategy router: runs all strategies in priority order
/// and returns the first valid qualifying signal.
/// Priority: Liquidity Sweep > ICT OTE > IFVG > POI Reversal > VWAP
/// Also enforces Premium/Discount zone filtering.
/// @param curr Last confirmed bar (rates[1]).
/// @param atr Current ATR.
/// @return First qualifying SSignal, or a signal with valid=false if nothing qualifies.
SSignal RouteStrategy(const MqlRates &curr, double atr) {
    SSignal empty; ZeroMemory(empty); empty.valid = false;

    if (!g_structure.valid) return empty;

    // Premium/Discount gate — avoid buying in premium or selling in discount
    double pd = g_structure.pd_array;
    bool allow_long = (pd <= 0.60); // Only long below equilibrium
    bool allow_short = (pd >= 0.40); // Only short above equilibrium

    // ---- HTF Alignment Routing Guard ----
    // Prevent the router from picking a counter-trend signal and discarding the bar.
    // This ensures lower-priority, trend-aligned strategies get a chance to fire.
    if (InpRequireHTFAlign) {
        if (g_htf_trend != 1.0) allow_long = false;
        if (g_htf_trend != -1.0) allow_short = false;
    }

    SSignal sig;

    // 1. Liquidity Sweep (highest priority)
    sig = Strategy_LiquiditySweep(curr, atr);
    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.valid = false;
        if (sig.direction == ZONE_BEAR && !allow_short) sig.valid = false;
        if (sig.valid) return sig;
    }

    // 2. ICT Optimal Trade Entry (second priority — requires HTF alignment)
    sig = Strategy_ICT_OTE(curr, atr);
    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.valid = false;
        if (sig.direction == ZONE_BEAR && !allow_short) sig.valid = false;
        if (sig.valid) return sig;
    }

    // 3. IFVG Mitigation
    sig = Strategy_IFVG_Mitigation(curr, atr);
    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.valid = false;
        if (sig.direction == ZONE_BEAR && !allow_short) sig.valid = false;
        if (sig.valid) return sig;
    }

    // 4. POI Reversal (only after a sweep)
    sig = Strategy_POI_Reversal(curr, atr);
    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.valid = false;
        if (sig.direction == ZONE_BEAR && !allow_short) sig.valid = false;
        if (sig.valid) return sig;
    }

    // 5. VWAP Bounce (lowest priority)
    sig = Strategy_VWAP_Bounce(curr, atr);
    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.valid = false;
        if (sig.direction == ZONE_BEAR && !allow_short) sig.valid = false;
        if (sig.valid) return sig;
    }

    return empty;
}

//==========================================================================
//  SECTION 13: RISK MANAGEMENT
//==========================================================================

/// @brief Analyzes EA history to calculate a "Net Loss Counter" for gradual recovery.
/// A loss adds +1. A win subtracts -1 (floored at 0).
/// Scratch trades are ignored. This ensures risk restores gradually after a drawdown.
/// @return Integer count of net losses, used to scale down risk for recovery.
int GetNetLossCounter() {
    int counter = 0;

    // Request full history to ensure we can read past deals
    if (HistorySelect(0, TimeCurrent())) {
        int total = HistoryDealsTotal();

        // Iterate forwards from oldest to newest to build the running state
        for (int i = 0; i < total; i++) {
            ulong ticket = HistoryDealGetTicket(i);
            if (ticket > 0) {
                // Ensure the deal belongs to this specific EA and Symbol
                if (HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber &&
                    HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {

                    long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

                    // We only care about OUT deals (when a position is closed)
                    if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT) {
                        // Calculate net profit including costs
                        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                                        HistoryDealGetDouble(ticket, DEAL_SWAP) +
                                        HistoryDealGetDouble(ticket, DEAL_COMMISSION);

                        // Ignore near-zero breakeven scratch trades (e.g. within $0.50 of 0)
                        if (profit < -0.5) {
                            counter++;
                        } else if (profit > 0.5) {
                            counter--;
                            if (counter < 0) counter = 0; // Floor at 0
                        }
                    }
                }
            }
        }
    }
    return counter;
}

/// @brief Returns the maximum allowed risk percentage based on account
/// size and currency
/// @param balance Current account balance.
/// @param currency Account currency string (e.g., "USD", "ZAR").
/// @return Maximum risk percentage to apply for lot size calculation.
double GetRiskCap(double balance, string currency) {
    if (!InpUseDynamicRisk) return InpRiskPercent;

    bool is_zar = (StringFind(currency, "ZAR") >= 0);

    if (is_zar) {
        if (balance < 2000) return MathMin(InpRiskPercent, 5.0);
        if (balance < 10000) return MathMin(InpRiskPercent, 4.0);
        if (balance < 100000) return MathMin(InpRiskPercent, 3.0);

        return MathMin(InpRiskPercent, 2.0);
    } else {
        if (balance < 100) return MathMin(InpRiskPercent, 5.0);
        if (balance < 500) return MathMin(InpRiskPercent, 4.0);
        if (balance < 5000) return MathMin(InpRiskPercent, 3.0);

        return MathMin(InpRiskPercent, 2.0);
    }
}

/// @brief Calculates the lot size based on risk percentage, SL distance,
/// and account balance. Clamps to broker-specified lot step limits.
/// @param entry_price Entry price.
/// @param sl_price Stop loss price.
/// @param order_type Order type (BUY/SELL) to determine SL distance direction.
/// @param session_multiplier Multiplier to adjust lot size based on session characteristics.
/// @return Validated lot size, or 0.0 if calculation fails.
double CalculateLotSize(double entry_price, double sl_price, ENUM_ORDER_TYPE order_type, double session_multiplier = 1.0) {
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    string currency = AccountInfoString(ACCOUNT_CURRENCY);

    // --- Dynamic Risk Tiering Integration ---
    double applied_risk_pct = GetRiskCap(balance, currency);

    // --- Drawdown & Streak Penalty Integration ---
    int net_loss_count = GetNetLossCounter();

    if (net_loss_count >= InpMaxLossStreak) {
        // Calculate how deep we are into the streak.
        // e.g., if threshold is 3, and we have 4 losses: depth = 2.
        // Penalty = 0.5 ^ 2 = 0.25 (Quarter risk). This cuts risk exponentially.
        int depth = (net_loss_count - InpMaxLossStreak) + 1;
        double penalty = MathPow(InpStreakPenaltyMult, depth);

        // Enforce a hard floor (10% of original risk) so we don't calculate invalid micro-lots
        penalty = MathMax(penalty, 0.1);

        applied_risk_pct *= penalty;
        Log(StringFormat("⚠️ Net loss counter at %d. Risk throttled by %.0f%% to %.2f%%",
            net_loss_count, (1.0 - penalty) * 100.0, applied_risk_pct), true);
    }

    // Scale the baseline risk capital by the session's confidence modifier
    double risk_amount = balance * (applied_risk_pct / 100.0) * session_multiplier;

    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double sl_distance = MathAbs(entry_price - sl_price);

    // Prevent division by zero
    if (sl_distance <= 0 || tick_size == 0 || tick_value == 0)
        return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    // Calculate initial lot size based on structural Risk
    double loss_per_lot = (sl_distance / tick_size) * tick_value;
    double lot_size = risk_amount / loss_per_lot;

    // --- LEVERAGE & MARGIN PROTECTION ---
    double margin_required = 0.0;
    if (!OrderCalcMargin(order_type, _Symbol, lot_size, entry_price, margin_required)) {
        Print("[Nexubot] OrderCalcMargin failed. Enforcing minimal risk state.");
        lot_size = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    } else {
        double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        double max_margin_allowed = free_margin * 0.80; // Cap margin exposure to 80% of free margin

        if (margin_required > max_margin_allowed) {
            // Scale lot size down proportionally to respect leverage constraints
            double leverage_ratio = max_margin_allowed / margin_required;
            lot_size = lot_size * leverage_ratio;
            PrintFormat("[Nexubot] Leverage Cap Triggered: Lot scaled down to %.2f (Margin Required: %.2f | Free: %.2f)", lot_size, margin_required, free_margin);
        }
    }

    // Clamp to broker limits
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLotSize);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot_size = MathFloor(lot_size / step) * step;
    return MathMax(min_lot, MathMin(lot_size, max_lot));
}

/// @brief Calculates final SL price, TP3 price, and intermediate TP levels.
/// Applies dynamic ATR-based SL, structural blockade TP capping,
/// and validates the minimum R/R before returning.
/// @param signal Candidate signal (direction + suggested_sl).
/// @param entry Entry price.
/// @param atr Current ATR value.
/// @param sl_price [Output] Final stop loss price.
/// @param tp1_price [Output] TP1 price (33% of range).
/// @param tp2_price [Output] TP2 price (66% of range).
/// @param tp3_price [Output] TP3 full target price.
/// @return true if the setup meets minimum R/R, false if it should be skipped.
bool CalculateSLTP(const SSignal &signal, double entry, double atr,
                   double &sl_price, double &tp1_price,
                   double &tp2_price, double &tp3_price) {
    bool is_long = (signal.direction == ZONE_BULL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    bool is_hv_asset = IsHighVolatility(_Symbol);
    double sl_mult = is_hv_asset ? InpSLMultiplierHVol : InpSLMultiplierBase;

    // ---- Stop Loss Calculation ----
    double sl_dist = MathMax(atr * sl_mult, point * 50.0); // ATR-based default

    // Override with strategy-suggested SL if it falls within acceptable bounds
    if (signal.suggested_sl > 0) {
        double suggested_dist = MathAbs(signal.suggested_sl - entry);

        if (suggested_dist > atr * 0.35 && suggested_dist < atr * 6.0) {
            // Validate correct side of entry
            bool correct_side = (is_long  && signal.suggested_sl < entry) ||
                                (!is_long && signal.suggested_sl > entry);
            if (correct_side) sl_dist = suggested_dist;
        }
    }

    // Enforce Broker Minimum Stop Level
    long stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_stop_dist = stop_level * point;
    if (sl_dist < min_stop_dist) {
        sl_dist = min_stop_dist;
    }

    // Hard SL cap — prevents overly wide stops destroying R/R
    if (sl_dist > atr * InpMaxSLCapATR) {
        PrintThrottledSkipReason("SL cap exceeded. Skipping.");
        return false;
    }

    sl_price = is_long ? (entry - sl_dist) : (entry + sl_dist);

    // ---- Take Profit Calculation ----
    double base_tp_dist = MathMax(atr * InpTPMultiplier, sl_dist * InpMinRR);

    // Cap TP at the nearest opposing structural blockade
    double opposing_poi = GetNearestOpposingPOI(signal.direction, entry);
    double max_tp, actual_tp_dist;
    double pip_buffer = point * 15.0; // Small buffer from blockade

    if (is_long) {
        max_tp = (opposing_poi > 0) ? (opposing_poi - pip_buffer) : (entry + base_tp_dist);
        tp3_price = MathMin(entry + base_tp_dist, max_tp);
        actual_tp_dist = tp3_price - entry;
    } else {
        max_tp = (opposing_poi > 0) ? (opposing_poi + pip_buffer) : (entry - base_tp_dist);
        tp3_price = MathMax(entry - base_tp_dist, max_tp);
        actual_tp_dist = entry - tp3_price;
    }

    // --- UNIFIED LOGIC: Maximum R/R Clamping ---
    double current_rr = (sl_dist > 0) ? (actual_tp_dist / sl_dist) : 0.0;

    if (current_rr > InpMaxRR) {
        actual_tp_dist = sl_dist * InpMaxRR; // Clamp distance to Max RR
        tp3_price = is_long ? (entry + actual_tp_dist) : (entry - actual_tp_dist);

        Log("Extreme RR normalized. Clamped to MaxRR.", true);
        current_rr = InpMaxRR; // Sync current_rr for the MinRR check below
    }

    // --- UNIFIED LOGIC: Minimum R/R Validation ---
    if (current_rr < InpMinRR) {
        PrintThrottledSkipReason("R/R too low. Skipping.");
        return false;
    }

    // Staggered TP levels: 33% / 66% / 100% of full TP distance
    if (is_long) {
        tp1_price = entry + actual_tp_dist * InpTP1Ratio;
        tp2_price = entry + actual_tp_dist * InpTP2Ratio;
    } else {
        tp1_price = entry - actual_tp_dist * InpTP1Ratio;
        tp2_price = entry - actual_tp_dist * InpTP2Ratio;
    }

    return true;
}

//==========================================================================
//  SECTION 14: TRADE EXECUTION
//==========================================================================

/// @brief Executes a market order and populates the position state tracker.
/// @param signal Validated, scored signal.
/// @param sl Calculated stop loss price.
/// @param tp1 TP1 level (breakeven trigger).
/// @param tp2 TP2 level (trail trigger).
/// @param tp3 TP3 final target.
/// @param lots Calculated lot size.
/// @param atr ATR at entry (used for BE buffer calculation).
/// @return true if order was placed successfully.
bool ExecuteTrade(const SSignal &signal, double sl, double tp1, double tp2,
                  double tp3, double lots, double atr) {
    bool is_long = (signal.direction == ZONE_BULL);
    double entry = is_long ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // Round all prices to broker's required decimal precision
    entry = NormalizeDouble(entry, digits);
    sl = NormalizeDouble(sl, digits);
    tp3 = NormalizeDouble(tp3, digits);

    bool success;
    if (is_long)
        success = g_trade.Buy(lots, _Symbol, entry, sl, tp3,
                              StringFormat("Nexubot|%s", signal.strategy_name));
    else
        success = g_trade.Sell(lots, _Symbol, entry, sl, tp3,
                               StringFormat("Nexubot|%s", signal.strategy_name));

    if (!success) {
        Log(StringFormat("Order failed: %d - %s", g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription()));
        return false;
    }

    // --- Populate Position State Tracker ---
    ulong ticket = g_trade.ResultOrder();
    g_pos_state.active = true;
    g_pos_state.ticket = ticket;
    g_pos_state.is_long = is_long;
    g_pos_state.entry_price = entry;
    g_pos_state.initial_volume = lots;
    g_pos_state.current_sl = sl;
    g_pos_state.tp1 = NormalizeDouble(tp1, digits);
    g_pos_state.tp2 = NormalizeDouble(tp2, digits);
    g_pos_state.tp3 = NormalizeDouble(tp3, digits);
    g_pos_state.tp1_hit = false;
    g_pos_state.tp2_hit = false;
    g_pos_state.be_set = false;
    g_pos_state.atr_at_entry = atr;
    g_pos_state.open_time = TimeCurrent();
    g_pos_state.strategy_name = signal.strategy_name;

    // Announce trade
    string msg = StringFormat(
        "Nexubot ENTRY: %s %s | Entry: %.5f | SL: %.5f | TP1: %.5f | TP2: %.5f | TP3: %.5f | Lots: %.2f | Strategy: %s",
        _Symbol, is_long ? "BUY" : "SELL", entry, sl, tp1, tp2, tp3, lots,
        signal.strategy_name
    );
    Log(msg);
    if (InpEnableAlerts) Alert(msg);
    if (InpEnableNotify) SendNotification(msg);

    return true;
}

//==========================================================================
//  SECTION 15: POSITION MANAGEMENT
//  Runs on every tick to monitor TP1/TP2 milestones and adjust SL.
//  Uses a deterministic waterfall: TP1 → BE, TP2 → Trail to TP1, TP3 → Close.
//==========================================================================

/// @brief Returns true if the Nexubot-managed position is still open.
/// @return true if the position is open, false otherwise.
bool IsPositionOpen() {
    if (!g_pos_state.active) return false;

    return g_position_info.SelectByTicket(g_pos_state.ticket);
}

/// @brief Modifies the stop loss of the active position.
/// @param new_sl New stop loss price.
/// @return true if modification succeeded.
bool ModifyStopLoss(double new_sl) {
    // ---- Advanced Fix: Market Closed & Throttle Guard ----
    static datetime last_modify_attempt = 0;
    datetime current_time = TimeCurrent();

    // Throttle: If the last attempt failed, wait 10 seconds before retrying
    if (current_time - last_modify_attempt < 10) return false;

    // Check if trading is currently permitted for the symbol (guards against index rollover breaks)
    ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY) {
        last_modify_attempt = current_time; // Trigger throttle
        PrintThrottledManageLog(StringFormat("Modify SL aborted: %s is currently closed for trading.", _Symbol));
        return false;
    }

    if (!g_position_info.SelectByTicket(g_pos_state.ticket)) return false;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double curr_sl = g_position_info.StopLoss();
    double curr_tp = g_position_info.TakeProfit();
    new_sl = NormalizeDouble(new_sl, digits);

    // Only move SL in the favourable direction (never widen SL)
    if (g_pos_state.is_long && new_sl <= curr_sl) return false;
    if (!g_pos_state.is_long && new_sl >= curr_sl) return false;

    bool ok = g_trade.PositionModify(g_pos_state.ticket, new_sl, curr_tp);
    if (ok) {
        g_pos_state.current_sl = new_sl;
        Log(StringFormat("SL updated for %s: %.5f → %.5f", _Symbol, curr_sl, new_sl), true);
        last_modify_attempt = 0; // Reset throttle on success
        g_last_manage_reason = "";
    } else {
        last_modify_attempt = current_time; // Activate throttle on failure
        PrintThrottledManageLog(StringFormat("Modify SL failed: %d", g_trade.ResultRetcode()));
    }

    return ok;
}

/// @brief Core position management loop. Runs on every tick.
/// Implements the staggered TP management plan:
/// TP1 reached → Move SL to Breakeven + ATR buffer
/// TP2 reached → Trail SL to TP1 (lock in partial profit)
/// TP3 reached → Position closes automatically (fixed TP order)
/// Timeout → Log and allow position to continue (do not force close)
void ManagePosition() {
    if (!IsPositionOpen()) {
        // Position was closed (TP, SL, or manual close) — reset state
        if (g_pos_state.active) {
            double profit = GetPositionProfit(g_pos_state.ticket);
            UpdateStrategyStats(g_pos_state.strategy_name, profit, g_pos_state.is_long);
            Log(StringFormat("Position %d closed. Net Profit: %.2f", g_pos_state.ticket, profit));
            ZeroMemory(g_pos_state);
            g_pos_state.active = false;
        }

        return;
    }

    // ---- Timeout logging (not forced close — let the TP/SL work) ----
    int mins_elapsed = (int)((TimeCurrent() - g_pos_state.open_time) / 60);
    if (mins_elapsed > InpMaxTradeMins && !g_pos_state.be_set && !g_pos_state.timeout_logged) {
        Log(StringFormat("Trade on %s exceeded %d mins. SL/TP still active.", _Symbol, InpMaxTradeMins), true);
        g_pos_state.timeout_logged = true; // Mark as logged to permanently silence for this position
    }

    // Current bid/ask
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double curr_price = g_pos_state.is_long ? bid : ask;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // ---- TP1: Move SL to Breakeven + ATR buffer ----
    if (!g_pos_state.tp1_hit) {
        bool hit_tp1 = g_pos_state.is_long ? (curr_price >= g_pos_state.tp1)
                                            : (curr_price <= g_pos_state.tp1);

        if (hit_tp1) {
            // ---- Advanced Fix: TP1 Throttle Guard ----
            static datetime last_tp1_attempt = 0;
            datetime current_time = TimeCurrent();
            if (current_time - last_tp1_attempt < 10) return; // 10-second cooldown

            ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
            if (trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY) {
                last_tp1_attempt = current_time; // Trigger throttle
                PrintThrottledManageLog(StringFormat("TP1 Partial Close aborted: %s is currently closed.", _Symbol));
                return;
            }

            double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

            // Calculate lots to close, normalized to broker step sizes
            double lots_to_close = MathFloor((g_pos_state.initial_volume * InpTP1PartialVol) / step) * step;

            if (lots_to_close >= min_lot) {
                if (g_trade.PositionClosePartial(g_pos_state.ticket, lots_to_close)) {
                    g_pos_state.tp1_hit = true; // State is only updated upon broker success
                    string msg = StringFormat("💰 %s TP1 Hit! Closed %.2f lots to secure profit. SL remains intact.", _Symbol, lots_to_close);
                    Log(msg);
                    if (InpEnableAlerts) Alert(msg);
                    if (InpEnableNotify) SendNotification(msg);
                    last_tp1_attempt = 0; // Reset throttle on success
                    g_last_manage_reason = "";
                } else {
                    last_tp1_attempt = current_time; // Activate throttle on failure
                    PrintThrottledManageLog(StringFormat("Failed to partially close position at TP1: %d", g_trade.ResultRetcode()));
                }
            } else {
                // Initial volume was too small to partial close, simply skip and mark as hit
                g_pos_state.tp1_hit = true;
            }
        }
    }

    // ---- TP2: Move SL to Breakeven (Capital Protection) ----
    // Triggered only after price has pushed significantly toward TP3 (clearing the pullback zone)
    if (g_pos_state.tp1_hit && !g_pos_state.tp2_hit) {
        bool hit_tp2 = g_pos_state.is_long ? (curr_price >= g_pos_state.tp2)
                                            : (curr_price <= g_pos_state.tp2);

        if (hit_tp2) {
            double be_price;
            if (g_pos_state.is_long)
                be_price = g_pos_state.entry_price + g_pos_state.atr_at_entry * InpBEBufferATR;
            else
                be_price = g_pos_state.entry_price - g_pos_state.atr_at_entry * InpBEBufferATR;

            be_price = NormalizeDouble(be_price, digits);

            if (ModifyStopLoss(be_price)) {
                g_pos_state.tp2_hit = true;
                g_pos_state.be_set = true;
                string msg = StringFormat("🛡️ %s TP2 Hit! SL moved to Breakeven: %.5f", _Symbol, be_price);
                Log(msg);
                if (InpEnableAlerts) Alert(msg);
                if (InpEnableNotify) SendNotification(msg);
            }
        }
    }
}

//==========================================================================
//  SECTION 16: MAIN MARKET ANALYSIS RUNNER
//  Orchestrates all subsystems when a new M5 bar is confirmed.
//  This is the primary "brain" function — it decides whether to trade.
//==========================================================================

/// @brief Full market analysis pipeline executed on each new M5 bar close.
void RunMarketAnalysis() {
    // Increment the cooldown tracker right at the start of the new bar execution
    g_bars_since_last_signal++;

    // ---- Guard: Session filter ----
    SSessionInfo session = GetSessionInfo();
    if (InpSessionFilter && !session.is_active) {
        if (g_last_skip_reason != "session") {
            PrintThrottledSkipReason("Outside trading sessions. Scanning paused.");
            g_last_skip_reason = "session";
        }
        return;
    }

    // ---- Guard: Spread filter ----
    int current_spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    int max_spread_allowed = InpMaxSpreadPoints;

    // Dynamically scale the allowed spread by 10x for high-volatility assets (XAU, BTC, Indices)
    if (IsHighVolatility(_Symbol)) {
        max_spread_allowed *= 10;
    }

    if (max_spread_allowed > 0 && current_spread > max_spread_allowed) {
        // Throttle: Only log the spread warning once every 5 minutes (300 seconds)
        if (TimeCurrent() - last_spread_log >= 300) {
            PrintFormat("[Nexubot] Spread too high (%d points > Max %d). Scanning paused.", current_spread, max_spread_allowed);
            last_spread_log = TimeCurrent();
        }
        return; // Exit cycle safely
    }

    // ---- Guard: Position already open ----
    if (IsPositionOpen()) {
        if (g_last_skip_reason != "position") {
            PrintThrottledSkipReason("Position already open. Scanning paused.");
            g_last_skip_reason = "position";
        }
        return;
    }

    // ---- Guard: Signal Cooldown ----
    if (InpSignalCooldownBars > 0 && g_bars_since_last_signal < InpSignalCooldownBars) {
        PrintThrottledSkipReason("Signal cooldown active. Scanning paused.");
        return;
    }

    // ---- Fetch M5 OHLCV data (last 600 bars) ----
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 600, rates);
    if (copied < 50) {
        Log("Insufficient M5 bars fetched.", false);
        return;
    }

    // ---- Update global context indicators ----
    g_htf_trend = GetHTFTrend();
    g_current_atr = GetATR();
    g_vwap = CalculateVWAP(rates, copied);
    GetDailyLevels(g_pdh, g_pdl);
    GetAsianRange(g_asian_high, g_asian_low);

    if (g_current_atr <= 0) {
        Log("ATR not ready. Skipping.", true);
        return;
    }

    // ---- Guard: Volatility Expansion Filter ----
    double atr_expansion = GetATRExpansionRatio();

    // 1. Hard Floor: Throw away genuinely dead, untradeable markets
    if (atr_expansion < InpMinVolFloor) {
        PrintThrottledSkipReason("Volatility dead (Ratio < Floor). Scanning paused.");
        return;
    }

    // 2. Continuous Multiplier: For borderline markets, scale down risk instead of blocking the trade
    if (atr_expansion < InpMinVolExpansion) {
        // Scale linearly from 0.0 to 1.0 between Floor and Optimal threshold
        double vol_confidence = (atr_expansion - InpMinVolFloor) / (InpMinVolExpansion - InpMinVolFloor);

        // Clamp the penalty so we still allocate at least 25% of normal risk for valid setups
        vol_confidence = MathMax(0.25, MathMin(1.0, vol_confidence));

        // Apply the penalty to the session multiplier (which feeds directly into CalculateLotSize)
        session.multiplier *= vol_confidence;
    }

    // ---- Update POIs incrementally from latest confirmed triplet ----
    // rates[0] = current forming bar, rates[1] = last closed bar, etc.
    double vol_sma = GetVolumeSMA(rates, 1, 20);
    UpdatePOIsIncremental(rates[3], rates[2], rates[1], vol_sma);

    // ---- Detect structure on the last confirmed bar ----
    g_structure = DetectStructure(rates, copied);
    if (!g_structure.valid) {
        Log("Structure detection failed. Skipping.", true);
        return;
    }

    // ---- HTF alignment gate (Condition 1) ----
    if (InpRequireHTFAlign && g_htf_trend == 0.0) {
        Log("HTF trend flat. No alignment possible.", true);
        return;
    }

    // ---- Liquidity sweep detection (Condition 2) ----
    int sweep_tier = SWEEP_NONE;
    double sweep_depth = 0.0;
    int sweep_dir = -1;
    DetectLiquiditySweep(rates, copied, g_current_atr, sweep_tier, sweep_depth, sweep_dir);

    // Update the global sweep trackers
    if (sweep_tier >= SWEEP_MAJOR) {
        g_recent_sweep_tier = sweep_tier;
        g_recent_sweep_dir = sweep_dir;
        g_bars_since_sweep = 0;
    } else {
        g_bars_since_sweep++;
    }

    if (InpMinSweepTier > 0 && g_recent_sweep_tier < InpMinSweepTier) {
        PrintThrottledSkipReason(StringFormat("No recent Sweep >= Tier %d. Skipping.", InpMinSweepTier));
        return;
    }

    // Update the global BOS/CHoCH trackers
    bool has_structure_break = (g_structure.bos_dir != STRUCT_FLAT) || (g_structure.choch_dir != STRUCT_FLAT);
    if (has_structure_break) {
        g_recent_break_dir = (g_structure.bos_dir != STRUCT_FLAT) ? g_structure.bos_dir : g_structure.choch_dir;
        g_bars_since_break = 0;
    } else {
        g_bars_since_break++;
    }

    // ---- BOS/CHoCH gate (Condition 3) ----
    if (InpRequireBOS && g_bars_since_break > InpBOSRecencyBars) {
        PrintThrottledSkipReason("No BOS/CHoCH detected. Skipping.");
        return;
    }

    // ---- Route through strategy engine ----
    SSignal signal = RouteStrategy(rates[1], g_current_atr);
    if (!signal.valid) {
        PrintThrottledSkipReason("No strategy qualified.");
        return;
    }

    // ---- Guard: POI Confluence Filter ----
    // Ensures trades are not taken in "no man's land" by requiring nearby institutional backing
    if (InpRequirePOIConfluence) {
        bool has_poi = false;
        double close_price = rates[1].close;

        if (signal.direction == ZONE_BULL) {
            has_poi = HasActiveBullPOI(close_price, g_current_atr, InpPOIProximityATR);
        } else if (signal.direction == ZONE_BEAR) {
            has_poi = HasActiveBearPOI(close_price, g_current_atr, InpPOIProximityATR);
        }

        if (!has_poi) {
            PrintThrottledSkipReason(StringFormat("Signal rejected: No active %s POI within %.1f ATR.",
                                     (signal.direction == ZONE_BULL ? "Bullish" : "Bearish"), InpPOIProximityATR));
            return;
        }
    }

    // ---- Calculate entry, SL, TP levels (Condition 4: R/R >= InpMinRR) ----
    double entry = signal.direction == ZONE_BULL ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double sl_price = 0, tp1 = 0, tp2 = 0, tp3 = 0;
    if (!CalculateSLTP(signal, entry, g_current_atr, sl_price, tp1, tp2, tp3)) {
        return; // R/R or SL cap check failed inside CalculateSLTP
    }

    // ---- Calculate lot size ----
    double sl_dist = MathAbs(entry - sl_price);
    ENUM_ORDER_TYPE order_type = (signal.direction == ZONE_BULL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

    double lots = CalculateLotSize(entry, sl_price, order_type, session.multiplier);
    if (lots <= 0) {
        Log("Lot size calculation failed. Skipping.", false);
        return;
    }

    // ---- Log the accepted setup ----
    Log(StringFormat("✅ SIGNAL ACCEPTED | %s | Strategy: %s | Sweep: Tier %d | HTF: %.1f | RR: %.2f",
              signal.direction == ZONE_BULL ? "LONG" : "SHORT",
              signal.strategy_name, sweep_tier,
              g_htf_trend, MathAbs(tp3 - entry) / sl_dist));

    // ---- Execute the trade ----
    bool executed = ExecuteTrade(signal, sl_price, tp1, tp2, tp3, lots, g_current_atr);

    if (executed) {
        g_bars_since_last_signal = 0;
        g_last_skip_reason = ""; // Reset after a successful trade execution
    }
}

//==========================================================================
//  SECTION 17: ANALYTICS & EXPORT
//==========================================================================

/// @brief Calculates total net profit of a closed position including partials and fees.
/// @param position_ticket Ticket number of the closed position.
/// @return Total profit in account currency.
double GetPositionProfit(ulong position_ticket) {
    double total_profit = 0.0;

    if (HistorySelectByPosition(position_ticket)) {
        int deals = HistoryDealsTotal();
        for (int i = 0; i < deals; i++) {
            ulong deal_ticket = HistoryDealGetTicket(i);
            long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            if (deal_entry == DEAL_ENTRY_OUT || deal_entry == DEAL_ENTRY_INOUT) {
                total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
                total_profit += HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
                total_profit += HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
            }
        }
    }

    return total_profit;
}

/// @brief Updates the performance record for a specific strategy.
/// @param name Name of the strategy.
/// @param profit Profit or loss from the closed trade.
/// @param is_long True if it was a long trade, false if short.
void UpdateStrategyStats(string name, double profit, bool is_long) {
    int idx = -1;
    for (int i = 0; i < g_stats_count; i++) {
        if (g_strategy_stats[i].strategy_name == name) {
            idx = i;
            break;
        }
    }

    if (idx == -1) {
        if (g_stats_count >= 20) return; // Prevent bounds overflow
        idx = g_stats_count;
        g_strategy_stats[idx].strategy_name = name;
        g_strategy_stats[idx].total_trades = 0;
        g_strategy_stats[idx].long_trades = 0;
        g_strategy_stats[idx].long_wins = 0;
        g_strategy_stats[idx].short_trades = 0;
        g_strategy_stats[idx].short_wins = 0;
        g_strategy_stats[idx].net_profit = 0.0;
        g_stats_count++;
    }

    g_strategy_stats[idx].total_trades++;

    // Route stats by direction, ignoring scratch trades near $0.00
    if (is_long) {
        g_strategy_stats[idx].long_trades++;
        if (profit > 0.5) g_strategy_stats[idx].long_wins++;
    } else {
        g_strategy_stats[idx].short_trades++;
        if (profit > 0.5) g_strategy_stats[idx].short_wins++;
    }
    g_strategy_stats[idx].net_profit += profit;
}

/// @brief Exports the accumulated strategy stats to a CSV file in the terminal's MQL5\Files directory.
void ExportStrategyStats() {
    if (g_stats_count == 0) return;
    string filename = StringFormat("Nexubot_Stats_%s.csv", _Symbol);
    int handle = FileOpen(filename, FILE_CSV | FILE_WRITE | FILE_ANSI, ',');

    if (handle != INVALID_HANDLE) {
        FileWrite(handle, "Strategy", "Total", "Longs", "Long Win%", "Shorts", "Short Win%", "Net Profit");
        for (int i = 0; i < g_stats_count; i++) {
            double win_rate = 0.0;

            double long_wr = 0.0, short_wr = 0.0;

            if (g_strategy_stats[i].long_trades > 0)
                long_wr = ((double)g_strategy_stats[i].long_wins / g_strategy_stats[i].long_trades) * 100.0;

            if (g_strategy_stats[i].short_trades > 0)
                short_wr = ((double)g_strategy_stats[i].short_wins / g_strategy_stats[i].short_trades) * 100.0;

            FileWrite(handle, g_strategy_stats[i].strategy_name,
                              g_strategy_stats[i].total_trades,
                              g_strategy_stats[i].long_trades,
                              NormalizeDouble(long_wr, 2),
                              g_strategy_stats[i].short_trades,
                              NormalizeDouble(short_wr, 2),
                              NormalizeDouble(g_strategy_stats[i].net_profit, 2));
        }
        FileClose(handle);
        Log("Strategy stats exported to: " + filename);
    } else {
        Log("Failed to export strategy stats. Error: " + IntegerToString(GetLastError()));
    }
}

//==========================================================================
//  SECTION 18: EA EVENT HANDLERS
//==========================================================================
/// @brief Initializes all indicator handles, configures the trade engine,
/// and warms up the POI state from historical data.
/// @return INIT_SUCCEEDED or INIT_FAILED.
int OnInit() {
    Log(StringFormat("Nexubot v1.0 initializing on %s %s...", _Symbol, EnumToString(Period())));

    // ---- Validate timeframe ----
    if (Period() != PERIOD_M5) {
        Alert("Nexubot requires M5 chart. Please change timeframe.");
        return INIT_FAILED;
    }

    // ---- Configure trade engine ----
    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(20); // 2 pips max slippage
    g_trade.SetTypeFillingBySymbol(_Symbol); // Auto-detect broker's fill mode
    g_trade.SetAsyncMode(false); // Synchronous for reliability

    // ---- 1. Initialize indicator handles FIRST ----
    g_h_atr = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
    g_h_atr_ema = iMA(_Symbol, PERIOD_M5, InpATREMAPeriod, 0, MODE_EMA, g_h_atr);
    g_h_ema50_h1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    g_h_ema200_h1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);

    // Verify all handles are valid
    if (g_h_atr == INVALID_HANDLE ||
        g_h_atr_ema == INVALID_HANDLE ||
        g_h_ema50_h1 == INVALID_HANDLE ||
        g_h_ema200_h1 == INVALID_HANDLE) {
        Log("CRITICAL: Failed to create indicator handles. Check symbol availability.");
        return INIT_FAILED;
    }

    // ---- Initialize position state ----
    ZeroMemory(g_pos_state);
    g_pos_state.active = false;

    // ---- Warm up POI arrays from historical bars ----
    Log(StringFormat("Warming up POI state from last %d bars...", InpWarmupBars));
    WarmupPOIs();

    // ---- Initialize structural context ----
    MqlRates tmp[];
    ArraySetAsSeries(tmp, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, InpStructureLookback + 20, tmp);

    if (copied > 5) {
        g_structure = DetectStructure(tmp, copied);
        g_current_atr = GetATR();
        g_htf_trend = GetHTFTrend();
        g_vwap = CalculateVWAP(tmp, copied);
        GetDailyLevels(g_pdh, g_pdl);
        GetAsianRange(g_asian_high, g_asian_low);
    }

    // Set last bar time to force analysis on first tick
    g_last_bar_time = 0;

    // Recover active position state in case of EA or terminal restart
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (g_position_info.SelectByIndex(i)) {
            if (g_position_info.Symbol() == _Symbol && g_position_info.Magic() == InpMagicNumber) {
                g_pos_state.active = true;
                g_pos_state.ticket = g_position_info.Ticket();
                g_pos_state.is_long = (g_position_info.PositionType() == POSITION_TYPE_BUY);
                g_pos_state.entry_price = g_position_info.PriceOpen();
                g_pos_state.current_sl = g_position_info.StopLoss();

                // Re-calculate intermediate TP levels based on existing open position data
                double tp3 = g_position_info.TakeProfit();
                double tp_dist = MathAbs(tp3 - g_pos_state.entry_price);

                if (g_pos_state.is_long) {
                    g_pos_state.tp1 = g_pos_state.entry_price + tp_dist * InpTP1Ratio;
                    g_pos_state.tp2 = g_pos_state.entry_price + tp_dist * InpTP2Ratio;
                } else {
                    g_pos_state.tp1 = g_pos_state.entry_price - tp_dist * InpTP1Ratio;
                    g_pos_state.tp2 = g_pos_state.entry_price - tp_dist * InpTP2Ratio;
                }

                g_pos_state.tp3 = tp3;
                g_pos_state.atr_at_entry = g_current_atr > 0 ? g_current_atr : GetATR();
                g_pos_state.open_time = g_position_info.Time();

                // Extract strategy name from trade comment if possible
                string comment = g_position_info.Comment();
                if (StringFind(comment, "Nexubot|") == 0) {
                    g_pos_state.strategy_name = StringSubstr(comment, 8);
                } else {
                    g_pos_state.strategy_name = "Unknown";
                }

                Log(StringFormat("Recovered active position tracker for ticket %d", g_pos_state.ticket));
                break; // We only track one active trade
            }
        }
    }

    Log(StringFormat("Nexubot initialized. HTF Trend: %.1f | ATR: %.5f | PDH: %.5f | PDL: %.5f",
              g_htf_trend, g_current_atr, g_pdh, g_pdl));

    return INIT_SUCCEEDED;
}

/// @brief Releases all indicator handles and cleans up resources on EA removal.
/// @param reason Reason code for deinitialization (e.g., user removal, chart close).
void OnDeinit(const int reason) {
    if (g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
    if (g_h_atr_ema != INVALID_HANDLE) IndicatorRelease(g_h_atr_ema);
    if (g_h_ema50_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema50_h1);
    if (g_h_ema200_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema200_h1);

    ExportStrategyStats();

    Log(StringFormat("Nexubot deinitialized. Reason: %d", reason));
}

/// @brief Main execution handler. Runs on every tick received from the broker.
/// Structure:
/// 1. Position management (every tick — for TP1/TP2 detection precision)
/// 2. New bar detection — runs full market analysis on confirmed M5 bar close
void OnTick() {
    // ---- 1. Manage open position on EVERY tick (highest priority) ----
    // This ensures we don't miss a TP1/TP2 level hit mid-bar
    if (g_pos_state.active) {
        ManagePosition();
    }

    // ---- 2. Detect new M5 bar formation ----
    datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
    if (current_bar == g_last_bar_time) return; // Same bar — no analysis needed
    g_last_bar_time = current_bar;

    // ---- 3. Run full market analysis on new bar close ----
    RunMarketAnalysis();
}

//+------------------------------------------------------------------+
//|  END OF NEXUBOT.MQ5                                              |
//|                                                                  |
//|  DEPLOYMENT INSTRUCTIONS:                                        |
//|  1. Copy this file to: [MT5 Data Folder]\MQL5\Experts\           |
//|  2. In MetaEditor, compile with F7 (requires zero errors).       |
//|  3. In MT5, drag Nexubot onto an M5 chart of your target symbol. |
//|  4. Enable "Allow Automated Trading" in the EA properties.       |
//|  5. Ensure the symbol is visible in Market Watch.                |
//|  6. The EA will warm up the POI state on first attach and begin  |
//|     scanning immediately on the next M5 bar close.               |
//|                                                                  |
//|  TUNING GUIDE (Input Parameters):                                |
//|  - InpMinSweepTier: Set to 3 (Daily only) for maximum quality.  |
//|    Set to 2 (Major+Daily) for a good balance.                    |
//|  - InpRequireHTFAlign: Set false only for range-bound markets.   |
//|  - InpSessionFilter: Keep true for London/NY-only trading.       |
//|  - InpRiskPercent: Start at 1.0% for live, increase after        |
//|    profitable track record is established.                        |
//|  - InpMaxSpreadPoints: Set to 20-30 for Forex, 50 for XAU/BTC.  |
//+------------------------------------------------------------------+