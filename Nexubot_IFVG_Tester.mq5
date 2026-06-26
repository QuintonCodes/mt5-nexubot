//+------------------------------------------------------------------+
//|                                         Nexubot_IFVG_Tester.mq5  |
//|                        Nexubot Systems © 2026                    |
//|                 Isolated IFVG Mitigation Strategy Tester         |
//+------------------------------------------------------------------+

#property copyright "Nexubot Systems © 2026"
#property link      "https://github.com/QuintonCodes/mt5-nexubot"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==========================================================================
//  SECTION 1: INPUT PARAMETERS
//==========================================================================

//--- Risk Management
input group           "==== RISK MANAGEMENT ===="
input double          InpRiskPercent       = 2.0;       // Risk per trade (% of balance)
input double          InpMaxLotSize        = 1.0;       // Hard cap on lot size
input double          InpMinRR             = 1.5;       // Min structural R/R before entry
input double          InpMaxRR             = 4.0;       // Hard cap on structural R/R to prevent over-extension
input bool            InpUseDynamicRisk    = true;      // Scale risk by account size tiers
input int             InpMaxLossStreak     = 2;         // Net loss count before risk is throttled
input double          InpStreakPenaltyMult = 0.3;       // Risk multiplier applied exponentially per loss beyond the threshold

//--- Entry Filters (The Strict Funnel)
input group           "==== ENTRY SIGNAL FILTERS ===="
input int             InpMinSweepTier      = 2;         // Min liquidity sweep tier (1/2/3)
input bool            InpRequireHTFAlign   = true;      // Require H1 trend aligned to signal
input bool            InpRequireBOS        = true;      // Require BOS or CHoCH confirmation
input bool            InpSessionFilter     = true;      // Only trade during active killzones
input int             InpMaxSpreadPoints   = 500;       // Max allowed spread in points (0=off)
input double          InpMinVolRatio       = 1.0;       // Min volume ratio for displacement
input bool            InpRequirePOIConfluence = true;   // Require setup to trigger near an active POI
input double          InpPOIProximityATR   = 3.0;       // Max distance to POI (x ATR) for confluence

//--- ATR & Volatility
input group           "==== ATR & VOLATILITY ===="
input int             InpATRPeriod         = 14;        // ATR calculation period
input int             InpATREMAPeriod      = 48;        // ATR EMA period (expansion baseline)
input double          InpMinVolExpansion   = 0.7;      // Optimal ATR expansion ratio (full risk)
input double          InpMinVolFloor       = 0.6;      // Absolute minimum expansion ratio (scaled risk floor)
input double          InpSLMultiplierBase  = 1.0;       // Base SL ATR multiplier
input double          InpSLMultiplierHVol  = 1.4;       // SL ATR multiplier for volatile assets
input double          InpMaxSLCapATR       = 2.0;       // Max SL cap (x ATR) — hard ceiling
input double          InpTPMultiplier      = 4.0;       // Base TP ATR multiplier

//--- SMC Structure Settings
input group           "==== SMC STRUCTURE DETECTION ===="
input double          InpSweepSLBufferATR  = 0.50;      // Stop loss buffer for liquidity sweep entries (x ATR)
input int             InpPivotLookback     = 6;         // Pivot detection window (bars each side)
input int             InpStructureLookback = 200;       // Structure detection depth (bars)
input int             InpMajorSwingPeriod  = 50;        // Major swing lookback (bars)
input int             InpSweepRecencyBars  = 48;        // Max bars since a Tier2+ sweep to remain "active"
input int             InpBOSRecencyBars    = 36;        // Max bars since a BOS/CHoCH to remain "active"

//--- POI (Point of Interest) Management
input group           "==== POI MANAGEMENT ===="
input int             InpMaxPOIsPerType    = 50;        // Max POIs tracked per type
input int             InpMaxPOIAgeBars     = 200;       // Max POI age before auto-expiry
input int             InpMaxMitigations    = 3;         // Mitigations before zone invalidation
input double          InpMinFVGVolRatio    = 1.4;       // Min vol ratio to create FVG
input double          InpMinOBBodyRatio    = 0.55;      // Min body/range ratio for OB candle
input double          InpMinOBVolRatio     = 1.2;       // Min vol ratio to create OB
input int             InpWarmupBars        = 500;       // Historical bars for POI warmup
input int             InpSignalCooldownBars = 3;        // Min bars to wait after a trade before allowing a new entry

//--- Session Times  (Adjust to your broker's server timezone offset)
input group           "==== SESSION TIMES (SERVER TIME) ===="
input int             InpAsianStart        = 2;         // Asian session start hour
input int             InpAsianEnd          = 10;        // Asian session end hour
input int             InpLondonStart       = 9;         // London session start hour
input int             InpLondonEnd         = 18;        // London session end hour
input int             InpNYStart           = 14;        // New York session start hour
input int             InpNYEnd             = 23;        // New York session end hour

//--- Multi-TP Exit Management
input group           "==== MULTI-TP EXIT MANAGEMENT ===="
input double          InpTP1Ratio          = 0.33;      // TP1 = % of full TP3 distance (Trigger for partial close)
input double          InpTP1PartialVol     = 0.50;      // Percentage of original lot size to close at TP1
input double          InpTP2Ratio          = 0.66;      // TP2 = % of full TP3 distance (Trigger for Trail to TP1)
input double          InpBEBufferATR       = 0.15;      // Breakeven buffer above entry (x ATR)
input int             InpMaxTradeMins      = 240;       // Max trade duration (minutes)

//--- Logging & Notifications
input group           "==== NOTIFICATIONS ===="
input bool            InpEnableAlerts      = true;      // Enable MT5 popup alerts
input bool            InpEnableNotify      = true;      // Enable mobile push notifications
input bool            InpVerboseLog        = true;      // Print verbose debug logs
input ulong           InpMagicNumber       = 20260611;  // EA magic number (unique per chart)

//==========================================================================
//  SECTION 2: CONSTANTS
//==========================================================================

#define MAX_ZONES 100

#define ZONE_BULL 0
#define ZONE_BEAR 1

#define OB_INTERNAL 0
#define OB_MAJOR 1
#define OB_BREAKER 2

#define SWEEP_NONE 0
#define SWEEP_INTERNAL 1
#define SWEEP_MAJOR 2
#define SWEEP_DAILY 3

#define STRUCT_FLAT 0
#define STRUCT_BULL 1
#define STRUCT_BEAR 2

//==========================================================================
//  SECTION 3: STRUCT DEFINITIONS
//==========================================================================

struct SZone {
    bool   active;
    int    zone_type;
    double zone_high;
    double zone_low;
    int    mitigations;
    bool   is_touching;
    int    age_bars;
    double vol_strength;
    int    ob_tier;
};

struct SStructureInfo {
    int    structure;
    int    bos_dir;
    int    choch_dir;
    double last_high;
    double last_low;
    double prev_high;
    double prev_low;
    double pd_array;
    bool   valid;
};

struct SSignal {
    bool   valid;
    int    direction;
    double suggested_sl;
    string strategy_name;
    string diagnostic;
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
    bool     timeout_logged;
};

struct SStrategyStats {
    string strategy_name;
    int    total_trades;
    int    long_trades;
    int    long_wins;
    int    short_trades;
    int    short_wins;
    double net_profit;
};

struct SDiagnosticStats {
    string reason;
    int    count;
};

struct SSessionInfo {
    bool   is_active;
    string session_name;
    double multiplier;
    bool   is_london_session;
};

//==========================================================================
//  SECTION 4: GLOBAL STATE VARIABLES
//==========================================================================

CTrade g_trade;
CPositionInfo g_position_info;

int g_h_atr = INVALID_HANDLE;
int g_h_atr_ema = INVALID_HANDLE;
int g_h_ema50_h1 = INVALID_HANDLE;
int g_h_ema200_h1 = INVALID_HANDLE;

SZone g_fvgs[MAX_ZONES];
SZone g_ifvgs[MAX_ZONES];
SZone g_obs[MAX_ZONES];
int g_fvg_count = 0;
int g_ifvg_count = 0;
int g_ob_count = 0;

SStructureInfo g_structure;
double g_htf_trend = 0.0;
double g_current_atr = 0.0;
double g_pdh = 0.0;
double g_pdl = 0.0;
double g_asian_high = 0.0;
double g_asian_low = 0.0;

SPositionState g_pos_state;

SStrategyStats g_strategy_stats[20];
int g_stats_count = 0;

SDiagnosticStats g_diag_stats[100];
int g_diag_count = 0;

datetime g_last_bar_time = 0;

string g_last_manage_reason = "";
static datetime last_spread_log = 0;

int g_bars_since_last_signal = 9999;
int g_bars_since_sweep = 9999;
int g_recent_sweep_tier = SWEEP_NONE;
double g_recent_sweep_depth = 0.0;
int g_recent_sweep_dir = -1;
int g_bars_since_break = 9999;
int g_recent_break_dir = STRUCT_FLAT;

string g_volatile_ids[] = {"XAU", "XAG", "BTC", "ETH", "US30", "NAS", "SPX", "UK100", "GER40"};

//==========================================================================
//  SECTION 5: UTILITY & TECHNICAL ANALYSIS HELPERS
//==========================================================================

double GetATR() {
    if (g_h_atr == INVALID_HANDLE) return 0.0;
    double MIN_ATR_FLOOR = 50 * _Point;
    double atr[];
    ArraySetAsSeries(atr, true);
    ResetLastError();

    int copied = CopyBuffer(g_h_atr, 0, 1, 1, atr);
    if (copied < 1) {
        int err = GetLastError();
        if (err != 4806 && InpVerboseLog) {
            PrintFormat("ATR CopyBuffer failed. Defaulting to dynamic floor. Error=%d", err);
        }
        return MIN_ATR_FLOOR;
    }

    return MathMax(atr[0], MIN_ATR_FLOOR);
}

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

    if (copied50  < 1) return 0.0;
    if (copied200 < 1) return 0.0;
    if (ema50[0] > ema200[0]) return  1.0;
    if (ema50[0] < ema200[0]) return -1.0;
    return 0.0;
}

double GetVolumeSMA(const MqlRates &rates[], int start, int period) {
    int total = ArraySize(rates);
    if (total < start + period) return 1.0;

    double sum = 0.0;
    for (int i = start; i < start + period; i++) sum += (double)rates[i].tick_volume;

    return MathMax(1.0, sum / period);
}

double GetBodyRatio(const MqlRates &bar) {
    double rng = bar.high - bar.low;
    if (rng <= 0) return 0.0;
    return MathMin(1.0, MathAbs(bar.close - bar.open) / rng);
}

bool IsHighVolatility(const string symbol) {
    string sym_upper = symbol;
    StringToUpper(sym_upper);
    int n = ArraySize(g_volatile_ids);

    for (int i = 0; i < n; i++) {
        if (StringFind(sym_upper, g_volatile_ids[i]) >= 0) return true;
    }
    return false;
}

void Log(const string msg, bool verbose_only = false) {
    if (verbose_only && !InpVerboseLog) return;
    PrintFormat("[Nexubot] %s", msg);
}

void PrintThrottledSkipReason(string reason) {
    static string tracked_reasons[20];
    static datetime tracked_times[20];
    static int track_count = 0;
    datetime current_time = TimeCurrent();
    int idx = -1;

    for (int i = 0; i < track_count; i++) {
        if (tracked_reasons[i] == reason) {
            idx = i;
            break;
        }
    }

    if (idx == -1) {
        if (track_count < 20) {
            idx = track_count;
            tracked_reasons[idx] = reason;
            tracked_times[idx] = 0;
            track_count++;
        } else {
            idx = 0;
        }
    }

    if (current_time - tracked_times[idx] >= 3600) {
        Log(reason, true);
        tracked_times[idx] = current_time;
    }
}

void PrintThrottledManageLog(string msg) {
    if (msg != g_last_manage_reason) {
        Log(msg, true);
        g_last_manage_reason = msg;
    }
}

//==========================================================================
//  SECTION 6: DAILY LEVELS & ASIAN RANGE
//==========================================================================

void GetDailyLevels(double &pdh, double &pdl) {
    MqlRates d1[];
    ArraySetAsSeries(d1, true);
    if (CopyRates(_Symbol, PERIOD_D1, 0, 3, d1) < 2) {
        pdh = 0.0;
        pdl = 0.0;
        return;
    }

    pdh = d1[1].high;
    pdl = d1[1].low;
}

void GetAsianRange(double &asian_high, double &asian_low) {
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 250, rates);
    asian_high = 0.0;
    asian_low = DBL_MAX;

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
            asian_low = MathMin(asian_low, rates[i].low);
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

//==========================================================================
//  SECTION 7: PIVOT DETECTION
//==========================================================================

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

//==========================================================================
//  SECTION 8: STRUCTURE DETECTION (BOS / CHoCH)
//==========================================================================

SStructureInfo DetectStructure(const MqlRates &rates[], int total) {
    SStructureInfo result;
    ZeroMemory(result);
    result.valid = false;

    if (total < InpStructureLookback + InpPivotLookback + 1) return result;

    double ph[4]; int ph_count = 0;
    double pl[4]; int pl_count = 0;

    int search_end = MathMin(total - InpPivotLookback - 1, InpStructureLookback);
    for (int i = InpPivotLookback; i < search_end && (ph_count < 4 || pl_count < 4); i++) {
        if (ph_count < 4 && IsPivotHigh(rates, i, InpPivotLookback))
            ph[ph_count++] = rates[i].high;
        if (pl_count < 4 && IsPivotLow(rates, i, InpPivotLookback))
            pl[pl_count++] = rates[i].low;
    }

    if (ph_count < 2 || pl_count < 2) return result;

    double last_high = ph[0], prev_high = ph[1];
    double last_low = pl[0], prev_low = pl[1];

    result.last_high = last_high;
    result.last_low = last_low;
    result.prev_high = prev_high;
    result.prev_low = prev_low;

    bool is_bull = (last_high > prev_high) && (last_low > prev_low);
    bool is_bear = (last_high < prev_high) && (last_low < prev_low);
    result.structure = is_bull ? STRUCT_BULL : (is_bear ? STRUCT_BEAR : STRUCT_FLAT);

    double curr_close = rates[1].close;
    result.bos_dir = STRUCT_FLAT;
    result.choch_dir = STRUCT_FLAT;

    if (curr_close > last_high) {
        if (result.structure == STRUCT_BEAR) result.choch_dir = STRUCT_BULL;
        else result.bos_dir = STRUCT_BULL;
    } else if (curr_close < last_low) {
        if (result.structure == STRUCT_BULL) result.choch_dir = STRUCT_BEAR;
        else result.bos_dir = STRUCT_BEAR;
    }

    double pd_range = last_high - last_low;
    result.pd_array = (pd_range > 0) ? MathMax(0.0, MathMin(1.0, (curr_close - last_low) / pd_range)) : 0.5;
    result.valid = true;

    return result;
}

//==========================================================================
//  SECTION 9: LIQUIDITY SWEEP DETECTION
//==========================================================================

bool IsRoundNumberSweep(double close_price, double recent_high, double recent_low, double atr) {
    if (close_price <= 0) return false;
    double magnitude = MathPow(10.0, MathFloor(MathLog10(close_price)));
    double step;

    if (magnitude <= 10) {
        step = 0.01;
    } else {
        step = magnitude / 100.0;
    }

    double closest_round = MathRound(close_price / step) * step;
    double dist_to_round = MathMin(
        MathAbs(recent_high - closest_round),
        MathAbs(recent_low  - closest_round)
    );
    return dist_to_round < (atr * 0.5);
}

void DetectLiquiditySweep(const MqlRates &rates[], int total,
                          double atr, int &tier, double &depth_atr, int &sweep_dir) {
    tier = SWEEP_NONE;
    depth_atr = 0.0;
    sweep_dir = -1;

    if (total < InpMajorSwingPeriod + 5 || atr <= 0) return;

    double close = rates[1].close;
    double rec_lo5 = GetRecentLow(rates, 1, 5);
    double rec_hi5 = GetRecentHigh(rates, 1, 5);

    int shift = 5;
    double major_lo50 = GetRecentLow(rates, 1 + shift, InpMajorSwingPeriod);
    double major_hi50 = GetRecentHigh(rates, 1 + shift, InpMajorSwingPeriod);

    SSessionInfo session = GetSessionInfo();

    if (g_pdl > 0 && rec_lo5 < g_pdl && close > g_pdl) {
        double depth = (g_pdl - rec_lo5) / atr;
        if (depth >= 0.12) {
            tier = SWEEP_DAILY;
            depth_atr = depth;
            sweep_dir = ZONE_BULL;
            return;
        }
    }
    if (g_pdh > 0 && rec_hi5 > g_pdh && close < g_pdh) {
        double depth = (rec_hi5 - g_pdh) / atr;
        if (depth >= 0.12) {
            tier = SWEEP_DAILY;
            depth_atr = depth;
            sweep_dir = ZONE_BEAR;
            return;
        }
    }

    if (session.is_london_session && g_asian_low > 0 && rec_lo5 < g_asian_low && close > g_asian_low) {
        double depth = (g_asian_low - rec_lo5) / atr;
        if (depth >= 0.12) {
            tier = SWEEP_DAILY;
            depth_atr = depth;
            sweep_dir = ZONE_BULL;
            return;
        }
    }
    if (session.is_london_session && g_asian_high > 0 && rec_hi5 > g_asian_high && close < g_asian_high) {
        double depth = (rec_hi5 - g_asian_high) / atr;
        if (depth >= 0.12) {
            tier = SWEEP_DAILY;
            depth_atr = depth;
            sweep_dir = ZONE_BEAR;
            return;
        }
    }

    if (major_lo50 > 0 && rec_lo5 < major_lo50 && close > major_lo50) {
        double depth = (major_lo50 - rec_lo5) / atr;
        if (depth >= 0.15) {
            tier = SWEEP_MAJOR;
            depth_atr = depth;
            sweep_dir = ZONE_BULL;
            return;
        }
    }
    if (major_hi50 > 0 && rec_hi5 > major_hi50 && close < major_hi50) {
        double depth = (rec_hi5 - major_hi50) / atr;
        if (depth >= 0.15) {
            tier = SWEEP_MAJOR;
            depth_atr = depth;
            sweep_dir = ZONE_BEAR;
            return;
        }
    }
    if (IsRoundNumberSweep(close, rec_hi5, rec_lo5, atr)) {
        tier = SWEEP_MAJOR;
        depth_atr = 0.5;
        sweep_dir = (rates[1].close > rates[1].open) ? ZONE_BULL : ZONE_BEAR;
        return;
    }

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
//==========================================================================

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

void AddZone(SZone &zones[], int &count, const SZone &new_zone) {
    int max_allowed = (int)MathMin(InpMaxPOIsPerType, MAX_ZONES);
    if (count < max_allowed) {
        zones[count] = new_zone;
        count++;
    } else {
        for (int i = 0; i < max_allowed - 1; i++) zones[i] = zones[i + 1];
        zones[max_allowed - 1] = new_zone;
        count = max_allowed;
    }
}

void UpdatePOIsIncremental(const MqlRates &c1, const MqlRates &c2,
                           const MqlRates &curr, double vol_sma_c2) {
    double curr_close = curr.close;
    double curr_low = curr.low;
    double curr_high = curr.high;

    for (int i = 0; i < g_fvg_count; i++) if (g_fvgs[i].active) g_fvgs[i].age_bars++;
    for (int i = 0; i < g_ifvg_count; i++) if (g_ifvgs[i].active) g_ifvgs[i].age_bars++;
    for (int i = 0; i < g_ob_count; i++) if (g_obs[i].active) g_obs[i].age_bars++;

    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active) continue;
        if (g_fvgs[i].zone_type == ZONE_BULL && curr_close < g_fvgs[i].zone_low) {
            SZone ifvg;
            ZeroMemory(ifvg);
            ifvg.active = true;
            ifvg.zone_type = ZONE_BEAR;
            ifvg.zone_high = g_fvgs[i].zone_high;
            ifvg.zone_low = g_fvgs[i].zone_low;
            AddZone(g_ifvgs, g_ifvg_count, ifvg);
            g_fvgs[i].active = false;
        } else if (g_fvgs[i].zone_type == ZONE_BEAR && curr_close > g_fvgs[i].zone_high) {
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
        if (g_obs[i].zone_type == ZONE_BULL && curr_close < g_obs[i].zone_low) {
            g_obs[i].zone_type = ZONE_BEAR;
            g_obs[i].ob_tier = OB_BREAKER;
            g_obs[i].mitigations = 0;
            g_obs[i].age_bars = 0;
            continue;
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

    double c2_vol_ratio = (vol_sma_c2 > 0) ? ((double)c2.tick_volume / vol_sma_c2) : 1.0;
    double c2_body_ratio = GetBodyRatio(c2);

    if (c2_vol_ratio >= InpMinFVGVolRatio && c2_body_ratio >= InpMinOBBodyRatio) {
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

    int ob_tier = (c2_vol_ratio >= 1.5) ? OB_MAJOR : OB_INTERNAL;

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

    CompactZoneArray(g_fvgs, g_fvg_count);
    CompactZoneArray(g_ifvgs, g_ifvg_count);
    CompactZoneArray(g_obs, g_ob_count);
}

void WarmupPOIs() {
    int warmup = MathMin(InpWarmupBars, 2000);
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, warmup + 25, rates);

    if (copied < 25) {
        Log("WarmupPOIs: Insufficient historical bars.", false);
        return;
    }

    g_fvg_count = 0; g_ifvg_count = 0; g_ob_count = 0;

    for (int k = copied - 25; k >= 1; k--) {
        double vol_sma_at_k = GetVolumeSMA(rates, k + 1, 20);
        UpdatePOIsIncremental(rates[k + 2], rates[k + 1], rates[k], vol_sma_at_k);
    }

    Log(StringFormat("POI Warmup: FVGs=%d, IFVGs=%d, OBs=%d",
              g_fvg_count, g_ifvg_count, g_ob_count));
}

bool HasActiveBullPOI(double close_price, double atr, double proximity = 0.5) {
    for (int i = 0; i < g_fvg_count; i++) {
        if (!g_fvgs[i].active || g_fvgs[i].zone_type != ZONE_BULL) continue;
        if (g_fvgs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_fvgs[i].zone_high);
        if (dist <= atr * proximity) return true;
    }
    for (int i = 0; i < g_ob_count; i++) {
        if (!g_obs[i].active || g_obs[i].zone_type != ZONE_BULL) continue;
        if (g_obs[i].mitigations >= InpMaxMitigations) continue;
        double dist = MathAbs(close_price - g_obs[i].zone_high);
        if (dist <= atr * proximity) return true;
    }
    return false;
}

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

double GetNearestOpposingPOI(int direction, double entry) {
    double nearest = 0.0;

    if (direction == ZONE_BULL) {
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

SSessionInfo GetSessionInfo() {
    SSessionInfo info;
    ZeroMemory(info);
    info.multiplier = 0.90;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;

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
    info.is_london_session = is_london;

    if (is_ny) {
        info.session_name = "NY";
        info.multiplier = 1.05;
    } else if (is_london) {
        info.session_name = "LONDON";
        info.multiplier = 1.03;
    } else if (is_asian) {
        info.session_name = "ASIAN";
        info.multiplier = 0.97;
    } else {
        info.session_name = "DEAD";
        info.multiplier = 0.90;
    }

    return info;
}

//==========================================================================
//  SECTION 12: SMC STRATEGY ANALYSIS FUNCTIONS
//==========================================================================

/// @brief STRATEGY: IFVG Mitigation Re-Test (Bullish & Bearish)
/// Enters after an Inverted Fair Value Gap acts as new support/resistance.
SSignal Strategy_IFVG_Mitigation(const MqlRates &curr, double atr) {
    SSignal sig; ZeroMemory(sig); sig.valid = false;

    // 1. Institutional Sweep Context Guard
    if (g_recent_sweep_tier < SWEEP_MAJOR || g_bars_since_sweep > InpSweepRecencyBars) {
        sig.diagnostic = "No recent Major/Daily sweep";
        return sig;
    }

    double close_price = curr.close;
    bool bouncing_down = close_price < curr.open;
    bool bouncing_up = close_price > curr.open;

    if (!bouncing_down && !bouncing_up) {
        sig.diagnostic = "No bounce detected";
        return sig;
    }

    double atr_buf = atr * 0.2;

    // 2. Bullish: Price bouncing off a BULL IFVG (former resistance acting as support)
    if (bouncing_up) {
        for (int i = 0; i < g_ifvg_count; i++) {
            if (!g_ifvgs[i].active || g_ifvgs[i].zone_type != ZONE_BULL) continue;
            if (g_ifvgs[i].mitigations > 2) continue;

            double ce_mid = (g_ifvgs[i].zone_high + g_ifvgs[i].zone_low) / 2.0;
            if (curr.low <= g_ifvgs[i].zone_high && close_price > ce_mid) {
                sig.valid = true;
                sig.direction = ZONE_BULL;
                sig.strategy_name = "IFVG Re-Test";

                // Anchor the SL below the entire IFVG zone
                double sl_anchor = MathMin(curr.low, g_ifvgs[i].zone_low);
                sig.suggested_sl = sl_anchor - atr_buf;
                return sig;
            }
        }
    }

    // 3. Bearish: Price bouncing off a BEAR IFVG (former support acting as resistance)
    if (bouncing_down) {
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

    sig.diagnostic = "No touching zone / invalid CE close";
    return sig;
}

/// @brief Isolated strategy router for IFVG Mitigation logic.
SSignal RouteStrategy(const MqlRates &curr, double atr) {
    SSignal empty; ZeroMemory(empty); empty.valid = false;

    if (!g_structure.valid) {
        empty.diagnostic = "Router: Structure invalid";
        return empty;
    }

    double pd = g_structure.pd_array;
    bool allow_long = (pd <= 0.60);
    bool allow_short = (pd >= 0.40);

    if (InpRequireHTFAlign) {
        if (g_htf_trend != 1.0) allow_long = false;
        if (g_htf_trend != -1.0) allow_short = false;
    }

    SSignal sig = Strategy_IFVG_Mitigation(curr, atr);

    if (sig.valid) {
        if (sig.direction == ZONE_BULL && !allow_long) sig.diagnostic = "PD/HTF blocked long";
        else if (sig.direction == ZONE_BEAR && !allow_short) sig.diagnostic = "PD/HTF blocked short";
        else return sig;
    }

    empty.diagnostic = "IFVG: " + sig.diagnostic;
    return empty;
}

//==========================================================================
//  SECTION 13: RISK MANAGEMENT
//==========================================================================

int GetNetLossCounter() {
    int counter = 0;
    const int MAX_COUNTER_CAP = 12;
    datetime current_time = TimeCurrent();
    datetime start_time = current_time - (30 * 24 * 60 * 60);

    if (HistorySelect(start_time, current_time)) {
        int total = HistoryDealsTotal();
        for (int i = 0; i < total; i++) {
            ulong ticket = HistoryDealGetTicket(i);
            if (ticket > 0) {
                if (HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber &&
                    HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {

                    long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
                    if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT) {
                        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                                        HistoryDealGetDouble(ticket, DEAL_SWAP) +
                                        HistoryDealGetDouble(ticket, DEAL_COMMISSION);

                        if (profit < -0.5) {
                            counter++;
                            if (counter > MAX_COUNTER_CAP) counter = MAX_COUNTER_CAP;
                        } else if (profit > 0.5) {
                            counter /= 2;
                        }
                    }
                }
            }
        }
    }
    return counter;
}

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

double CalculateLotSize(double entry_price, double sl_price, ENUM_ORDER_TYPE order_type, double session_multiplier = 1.0) {
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    string currency = AccountInfoString(ACCOUNT_CURRENCY);

    double applied_risk_pct = GetRiskCap(balance, currency);
    int net_loss_count = GetNetLossCounter();

    if (net_loss_count >= InpMaxLossStreak) {
        int depth = (net_loss_count - InpMaxLossStreak) + 1;
        double penalty = MathPow(InpStreakPenaltyMult, depth);
        penalty = MathMax(penalty, 0.1);
        applied_risk_pct *= penalty;
        Log(StringFormat("⚠️ Net loss counter at %d. Risk throttled by %.0f%% to %.2f%%",
            net_loss_count, (1.0 - penalty) * 100.0, applied_risk_pct), true);
    }

    double risk_amount = balance * (applied_risk_pct / 100.0) * session_multiplier;
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double sl_distance = MathAbs(entry_price - sl_price);

    if (sl_distance <= 0 || tick_size == 0 || tick_value == 0)
        return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double loss_per_lot = (sl_distance / tick_size) * tick_value;
    double lot_size = risk_amount / loss_per_lot;

    double margin_required = 0.0;
    if (!OrderCalcMargin(order_type, _Symbol, lot_size, entry_price, margin_required)) {
        Log("OrderCalcMargin failed. Enforcing minimal risk state.", true);
        lot_size = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    } else {
        double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        double max_margin_allowed = free_margin * 0.80;

        if (margin_required > max_margin_allowed) {
            double leverage_ratio = max_margin_allowed / margin_required;
            lot_size = lot_size * leverage_ratio;
            Log(StringFormat("Leverage Cap Triggered: Lot scaled down to %.2f (Margin Required: %.2f | Free: %.2f)",
                lot_size, margin_required, free_margin), true);
        }
    }

    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLotSize);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot_size = MathFloor(lot_size / step) * step;
    return MathMax(min_lot, MathMin(lot_size, max_lot));
}

bool CalculateSLTP(const SSignal &signal, double entry, double atr,
                   double &sl_price, double &tp1_price,
                   double &tp2_price, double &tp3_price) {
    bool is_long = (signal.direction == ZONE_BULL);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    bool is_hv_asset = IsHighVolatility(_Symbol);
    double sl_mult = is_hv_asset ? InpSLMultiplierHVol : InpSLMultiplierBase;

    double sl_dist = MathMax(atr * sl_mult, point * 50.0);

    if (signal.suggested_sl > 0) {
        double suggested_dist = MathAbs(signal.suggested_sl - entry);
        if (suggested_dist > atr * 0.35 && suggested_dist < atr * 6.0) {
            bool correct_side = (is_long  && signal.suggested_sl < entry) ||
                                (!is_long && signal.suggested_sl > entry);
            if (correct_side) sl_dist = suggested_dist;
        }
    }

    long stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double min_stop_dist = stop_level * point;
    if (sl_dist < min_stop_dist) {
        sl_dist = min_stop_dist;
    }

    if (sl_dist > atr * InpMaxSLCapATR) {
        PrintThrottledSkipReason("SL cap exceeded. Skipping.");
        return false;
    }

    sl_price = is_long ? (entry - sl_dist) : (entry + sl_dist);

    double opposing_poi = GetNearestOpposingPOI(signal.direction, entry);
    double pip_buffer = point * 15.0;
    double structural_tp = 0.0;
    double actual_tp_dist;

    double actual_min_rr = InpMinRR;
    double min_tp_dist = sl_dist * actual_min_rr;

    double base_tp = 0.0;
    double safe_multiplier = MathMin(InpTPMultiplier, 5.0);

    if (is_long) {
        if (g_pdh - pip_buffer >= entry + min_tp_dist) base_tp = g_pdh - pip_buffer;
        else if (g_asian_high - pip_buffer >= entry + min_tp_dist) base_tp = g_asian_high - pip_buffer;
        else base_tp = entry + (sl_dist * safe_multiplier);

        if (opposing_poi > entry) {
            double dist_to_base = MathAbs(base_tp - opposing_poi);
            if (opposing_poi - pip_buffer <= entry + min_tp_dist) {
                structural_tp = base_tp;
            } else if (opposing_poi - pip_buffer < base_tp) {
                structural_tp = opposing_poi - pip_buffer;
            } else if (dist_to_base <= 1.5 * atr) {
                structural_tp = opposing_poi - pip_buffer;
            } else {
                structural_tp = base_tp;
            }
        } else {
            structural_tp = base_tp;
        }

        tp3_price = structural_tp;
        actual_tp_dist = tp3_price - entry;
    } else {
        if (g_pdl > 0 && g_pdl + pip_buffer <= entry - min_tp_dist) base_tp = g_pdl + pip_buffer;
        else if (g_asian_low > 0 && g_asian_low + pip_buffer <= entry - min_tp_dist) base_tp = g_asian_low + pip_buffer;
        else base_tp = entry - (sl_dist * safe_multiplier);

        if (opposing_poi > 0 && opposing_poi < entry) {
            double dist_to_base = MathAbs(base_tp - opposing_poi);
            if (opposing_poi + pip_buffer >= entry - min_tp_dist) {
                structural_tp = base_tp;
            } else if (opposing_poi + pip_buffer > base_tp) {
                structural_tp = opposing_poi + pip_buffer;
            } else if (dist_to_base <= 1.5 * atr) {
                structural_tp = opposing_poi + pip_buffer;
            } else {
                structural_tp = base_tp;
            }
        } else {
            structural_tp = base_tp;
        }

        tp3_price = structural_tp;
        actual_tp_dist = entry - tp3_price;
    }

    double current_rr = (sl_dist > 0) ? (actual_tp_dist / sl_dist) : 0.0;

    if (current_rr > InpMaxRR) {
        actual_tp_dist = sl_dist * InpMaxRR;
        tp3_price = is_long ? (entry + actual_tp_dist) : (entry - actual_tp_dist);

        Log("Extreme RR normalized. Clamped to MaxRR.", true);
        current_rr = InpMaxRR;
    }

    if (current_rr < InpMinRR) {
        PrintThrottledSkipReason("R/R too low. Skipping.");
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

//==========================================================================
//  SECTION 14: TRADE EXECUTION
//==========================================================================

bool ExecuteTrade(const SSignal &signal, double sl, double tp1, double tp2,
                  double tp3, double lots, double atr) {
    bool is_long = (signal.direction == ZONE_BULL);
    double entry = is_long ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

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
//==========================================================================

bool IsPositionOpen() {
    if (!g_pos_state.active) return false;
    return g_position_info.SelectByTicket(g_pos_state.ticket);
}

bool ModifyStopLoss(double new_sl) {
    static datetime last_modify_attempt = 0;
    datetime current_time = TimeCurrent();

    if (current_time - last_modify_attempt < 10) return false;

    ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY) {
        last_modify_attempt = current_time;
        PrintThrottledManageLog(StringFormat("Modify SL aborted: %s is currently closed for trading.", _Symbol));
        return false;
    }

    if (!g_position_info.SelectByTicket(g_pos_state.ticket)) return false;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double curr_sl = g_position_info.StopLoss();
    double curr_tp = g_position_info.TakeProfit();
    new_sl = NormalizeDouble(new_sl, digits);

    if (g_pos_state.is_long && new_sl <= curr_sl) return false;
    if (!g_pos_state.is_long && new_sl >= curr_sl) return false;

    bool ok = g_trade.PositionModify(g_pos_state.ticket, new_sl, curr_tp);
    if (ok) {
        g_pos_state.current_sl = new_sl;
        Log(StringFormat("SL updated for %s: %.5f → %.5f", _Symbol, curr_sl, new_sl), true);
        last_modify_attempt = 0;
        g_last_manage_reason = "";
    } else {
        last_modify_attempt = current_time;
        PrintThrottledManageLog(StringFormat("Modify SL failed: %d", g_trade.ResultRetcode()));
    }

    return ok;
}

void ManagePosition() {
    if (!IsPositionOpen()) {
        if (g_pos_state.active) {
            double profit = GetPositionProfit(g_pos_state.ticket);
            UpdateStrategyStats(g_pos_state.strategy_name, profit, g_pos_state.is_long);
            Log(StringFormat("Position %d closed. Net Profit: %.2f", g_pos_state.ticket, profit));
            ZeroMemory(g_pos_state);
            g_pos_state.active = false;
        }
        return;
    }

    int mins_elapsed = (int)((TimeCurrent() - g_pos_state.open_time) / 60);
    if (mins_elapsed > InpMaxTradeMins && !g_pos_state.be_set && !g_pos_state.timeout_logged) {
        Log(StringFormat("Trade on %s exceeded %d mins. SL/TP still active.", _Symbol, InpMaxTradeMins), true);
        g_pos_state.timeout_logged = true;
    }

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double curr_price = g_pos_state.is_long ? bid : ask;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    if (!g_pos_state.tp1_hit) {
        bool hit_tp1 = g_pos_state.is_long ?
                       (curr_price >= g_pos_state.tp1) : (curr_price <= g_pos_state.tp1);

        if (hit_tp1) {
            static datetime last_tp1_attempt = 0;
            datetime current_time = TimeCurrent();
            if (current_time - last_tp1_attempt < 10) return;

            ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
            if (trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY) {
                last_tp1_attempt = current_time;
                PrintThrottledManageLog(StringFormat("TP1 Management aborted: %s is currently closed.", _Symbol));
                return;
            }

            double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

            double lots_to_close = MathFloor((g_pos_state.initial_volume * InpTP1PartialVol) / step) * step;

            double be_price = g_pos_state.is_long ?
                              (g_pos_state.entry_price + g_pos_state.atr_at_entry * InpBEBufferATR) :
                              (g_pos_state.entry_price - g_pos_state.atr_at_entry * InpBEBufferATR);
            be_price = NormalizeDouble(be_price, digits);

            if (lots_to_close >= min_lot) {
                if (g_trade.PositionClosePartial(g_pos_state.ticket, lots_to_close)) {
                    g_pos_state.tp1_hit = true;
                    if (ModifyStopLoss(be_price)) {
                        g_pos_state.be_set = true;
                        string msg = StringFormat("💰 %s TP1 Hit! Closed %.2f lots. SL moved to BE: %.5f", _Symbol, lots_to_close, be_price);
                        Log(msg);
                        if (InpEnableAlerts) Alert(msg);
                        if (InpEnableNotify) SendNotification(msg);
                    } else {
                        string msg = StringFormat("💰 %s TP1 Hit! Closed %.2f lots. SL BE move delayed.", _Symbol, lots_to_close);
                        Log(msg);
                        if (InpEnableAlerts) Alert(msg);
                        if (InpEnableNotify) SendNotification(msg);
                    }

                    last_tp1_attempt = 0;
                    g_last_manage_reason = "";
                } else {
                    last_tp1_attempt = current_time;
                    PrintThrottledManageLog(StringFormat("Failed to partially close position at TP1: %d", g_trade.ResultRetcode()));
                }
            } else {
                if (ModifyStopLoss(be_price)) {
                    g_pos_state.tp1_hit = true;
                    g_pos_state.be_set = true;
                    string msg = StringFormat("🛡️ %s TP1 Hit! Vol too small for partial. SL moved to Breakeven: %.5f", _Symbol, be_price);
                    Log(msg);
                    if (InpEnableAlerts) Alert(msg);
                    if (InpEnableNotify) SendNotification(msg);
                    last_tp1_attempt = 0;
                    g_last_manage_reason = "";
                } else {
                    double curr_sl = g_position_info.StopLoss();
                    bool already_better = g_pos_state.is_long ? (curr_sl >= be_price) : (curr_sl <= be_price);

                    if (already_better) {
                        g_pos_state.tp1_hit = true;
                        g_pos_state.be_set = true;
                        Log("🛡️ TP1 Hit: SL already at or better than BE for micro-lot.", true);
                    } else {
                        last_tp1_attempt = current_time;
                        PrintThrottledManageLog(StringFormat("Failed to move SL to BE at TP1 for micro-lot: %d", g_trade.ResultRetcode()));
                    }
                }
            }
        }
    }

    if (g_pos_state.tp1_hit && !g_pos_state.tp2_hit) {
        bool hit_tp2 = g_pos_state.is_long ?
                       (curr_price >= g_pos_state.tp2) : (curr_price <= g_pos_state.tp2);

        if (hit_tp2) {
            double trail_price = g_pos_state.tp1;
            if (ModifyStopLoss(trail_price)) {
                g_pos_state.tp2_hit = true;
                g_pos_state.be_set = true;
                string msg = StringFormat("🛡️ %s TP2 Hit! SL trailed to TP1 to lock in profit: %.5f", _Symbol, trail_price);
                Log(msg);
                if (InpEnableAlerts) Alert(msg);
                if (InpEnableNotify) SendNotification(msg);
            } else {
                double curr_sl = g_position_info.StopLoss();
                bool already_better = g_pos_state.is_long ? (curr_sl >= trail_price) : (curr_sl <= trail_price);
                if (already_better) {
                    g_pos_state.tp2_hit = true;
                } else {
                    PrintThrottledManageLog(StringFormat("Failed to trail SL at TP2: %d", g_trade.ResultRetcode()));
                }
            }
        }
    }
}

//==========================================================================
//  SECTION 16: MAIN MARKET ANALYSIS RUNNER
//==========================================================================

void RunMarketAnalysis() {
    g_bars_since_last_signal++;

    SSessionInfo session = GetSessionInfo();
    if (InpSessionFilter && !session.is_active) {
        PrintThrottledSkipReason("Outside trading sessions. Scanning paused.");
        return;
    }

    int current_spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    int max_spread_allowed = InpMaxSpreadPoints;

    if (IsHighVolatility(_Symbol)) {
        max_spread_allowed *= 10;
    }

    if (max_spread_allowed > 0 && current_spread > max_spread_allowed) {
        if (TimeCurrent() - last_spread_log >= 300) {
            Log(StringFormat("Spread too high (%d points > Max %d). Scanning paused.",
                current_spread, max_spread_allowed), true);
            last_spread_log = TimeCurrent();
        }
        return;
    }

    if (IsPositionOpen()) {
        PrintThrottledSkipReason("Position already open. Scanning paused.");
        return;
    }

    if (InpSignalCooldownBars > 0 && g_bars_since_last_signal < InpSignalCooldownBars) {
        PrintThrottledSkipReason("Signal cooldown active. Scanning paused.");
        return;
    }

    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 600, rates);

    if (copied < 50) {
        Log("Insufficient M5 bars fetched.", false);
        return;
    }

    g_htf_trend = GetHTFTrend();
    g_current_atr = GetATR();
    GetDailyLevels(g_pdh, g_pdl);
    GetAsianRange(g_asian_high, g_asian_low);

    if (g_current_atr <= 0) {
        Log("ATR not ready. Skipping.", true);
        return;
    }

    double atr_expansion = GetATRExpansionRatio();
    if (atr_expansion < InpMinVolFloor) {
        PrintThrottledSkipReason("Volatility dead (Ratio < Floor). Scanning paused.");
        return;
    }

    if (atr_expansion < InpMinVolExpansion) {
        double vol_confidence = (atr_expansion - InpMinVolFloor) / (InpMinVolExpansion - InpMinVolFloor);
        vol_confidence = MathMax(0.25, MathMin(1.0, vol_confidence));
        session.multiplier *= vol_confidence;
    }

    double vol_sma = GetVolumeSMA(rates, 1, 20);
    UpdatePOIsIncremental(rates[3], rates[2], rates[1], vol_sma);

    g_structure = DetectStructure(rates, copied);
    if (!g_structure.valid) {
        Log("Structure detection failed. Skipping.", true);
        return;
    }

    if (InpRequireHTFAlign && g_htf_trend == 0.0) {
        Log("HTF trend flat. No alignment possible.", true);
        return;
    }

    int sweep_tier = SWEEP_NONE;
    double sweep_depth = 0.0;
    int sweep_dir = -1;
    DetectLiquiditySweep(rates, copied, g_current_atr, sweep_tier, sweep_depth, sweep_dir);

    if (sweep_tier >= SWEEP_MAJOR) {
        bool active_daily = (g_recent_sweep_tier == SWEEP_DAILY &&
                             g_bars_since_sweep <= InpSweepRecencyBars &&
                             g_recent_sweep_dir == sweep_dir);

        if (!active_daily || sweep_tier == SWEEP_DAILY) {
            g_recent_sweep_tier = sweep_tier;
            g_recent_sweep_dir = sweep_dir;
            g_recent_sweep_depth = sweep_depth;
            g_bars_since_sweep = 0;
        } else {
            g_bars_since_sweep++;
        }
    } else {
        g_bars_since_sweep++;
    }

    if (InpMinSweepTier > 0 && g_recent_sweep_tier < InpMinSweepTier) {
        PrintThrottledSkipReason(StringFormat("No recent Sweep >= Tier %d. Skipping.", InpMinSweepTier));
        return;
    }

    bool has_structure_break = (g_structure.bos_dir != STRUCT_FLAT) ||
                               (g_structure.choch_dir != STRUCT_FLAT);
    if (has_structure_break) {
        g_recent_break_dir = (g_structure.bos_dir != STRUCT_FLAT) ?
                             g_structure.bos_dir : g_structure.choch_dir;
        g_bars_since_break = 0;
    } else {
        g_bars_since_break++;
    }

    if (InpRequireBOS && g_bars_since_break > InpBOSRecencyBars) {
        PrintThrottledSkipReason("No BOS/CHoCH detected. Skipping.");
        return;
    }

    SSignal signal = RouteStrategy(rates[1], g_current_atr);

    if (!signal.valid) {
        PrintThrottledSkipReason("No strategy qualified. (Diagnostics logging to CSV)");
        UpdateDiagnosticStats(signal.diagnostic);
        return;
    }

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

    double entry = signal.direction == ZONE_BULL ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double sl_price = 0, tp1 = 0, tp2 = 0, tp3 = 0;

    if (!CalculateSLTP(signal, entry, g_current_atr, sl_price, tp1, tp2, tp3)) {
        return;
    }

    double sl_dist = MathAbs(entry - sl_price);
    ENUM_ORDER_TYPE order_type = (signal.direction == ZONE_BULL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

    double lots = CalculateLotSize(entry, sl_price, order_type, session.multiplier);
    if (lots <= 0) {
        Log("Lot size calculation failed. Skipping.", false);
        return;
    }

    Log(StringFormat("✅ SIGNAL ACCEPTED | %s | Strategy: %s | Sweep: Tier %d | HTF: %.1f | RR: %.2f",
              signal.direction == ZONE_BULL ? "LONG" : "SHORT",
              signal.strategy_name, sweep_tier,
              g_htf_trend, MathAbs(tp3 - entry) / sl_dist));

    bool executed = ExecuteTrade(signal, sl_price, tp1, tp2, tp3, lots, g_current_atr);
    if (executed) {
        g_bars_since_last_signal = 0;
    }
}

//==========================================================================
//  SECTION 17: ANALYTICS & EXPORT
//==========================================================================

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

void UpdateStrategyStats(string name, double profit, bool is_long) {
    int idx = -1;
    for (int i = 0; i < g_stats_count; i++) {
        if (g_strategy_stats[i].strategy_name == name) {
            idx = i;
            break;
        }
    }

    if (idx == -1) {
        if (g_stats_count >= 20) return;
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

    if (is_long) {
        g_strategy_stats[idx].long_trades++;
        if (profit > 0.5) g_strategy_stats[idx].long_wins++;
    } else {
        g_strategy_stats[idx].short_trades++;
        if (profit > 0.5) g_strategy_stats[idx].short_wins++;
    }

    g_strategy_stats[idx].net_profit += profit;
}

void ExportStrategyStats() {
    if (g_stats_count == 0) return;
    string filename = StringFormat("Nexubot_Stats_%s.csv", _Symbol);
    int handle = FileOpen(filename, FILE_CSV | FILE_WRITE | FILE_ANSI, ',');

    if (handle != INVALID_HANDLE) {
        FileWrite(handle, "Strategy", "Total", "Longs", "Long Win%", "Shorts", "Short Win%", "Net Profit");

        for (int i = 0; i < g_stats_count; i++) {
            if (g_strategy_stats[i].total_trades < 20) continue;

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

        FileWrite(handle, "");
        FileWrite(handle, "--- INSUFFICIENT DATA (< 20 TRADES) ---", "", "", "", "", "", "");

        for (int i = 0; i < g_stats_count; i++) {
            if (g_strategy_stats[i].total_trades >= 20) continue;

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

void UpdateDiagnosticStats(string aggregated_diagnostic) {
    if (aggregated_diagnostic == "") return;

    string reasons[];
    int num_reasons = StringSplit(aggregated_diagnostic, (ushort)'|', reasons);

    for (int i = 0; i < num_reasons; i++) {
        string r = reasons[i];
        StringTrimLeft(r);
        StringTrimRight(r);
        if (r == "") continue;

        int idx = -1;
        for (int j = 0; j < g_diag_count; j++) {
            if (g_diag_stats[j].reason == r) {
                idx = j;
                break;
            }
        }

        if (idx == -1) {
            if (g_diag_count >= 100) continue;
            idx = g_diag_count;
            g_diag_stats[idx].reason = r;
            g_diag_stats[idx].count = 0;
            g_diag_count++;
        }

        g_diag_stats[idx].count++;
    }
}

void ExportDiagnosticStats() {
    if (g_diag_count == 0) return;

    string filename = StringFormat("Nexubot_Diagnostics_%s.csv", _Symbol);
    int handle = FileOpen(filename, FILE_CSV | FILE_WRITE | FILE_ANSI, ',');

    if (handle != INVALID_HANDLE) {
        FileWrite(handle, "Diagnostic Reason", "Count");
        for (int i = 0; i < g_diag_count; i++) {
            FileWrite(handle, g_diag_stats[i].reason, g_diag_stats[i].count);
        }
        FileClose(handle);
        Log("Diagnostic stats exported to: " + filename);
    } else {
        Log("Failed to export diagnostic stats. Error: " + IntegerToString(GetLastError()), true);
    }
}

//==========================================================================
//  SECTION 18: EA EVENT HANDLERS
//==========================================================================

int OnInit() {
    Log(StringFormat("Nexubot v1.0 initializing on %s %s...", _Symbol, EnumToString(Period())));

    if (Period() != PERIOD_M5) {
        Alert("Nexubot requires M5 chart. Please change timeframe.");
        return INIT_FAILED;
    }

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(20);
    g_trade.SetTypeFillingBySymbol(_Symbol);
    g_trade.SetAsyncMode(false);

    g_h_atr = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
    g_h_atr_ema = iMA(_Symbol, PERIOD_M5, InpATREMAPeriod, 0, MODE_EMA, g_h_atr);
    g_h_ema50_h1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    g_h_ema200_h1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);

    if (g_h_atr == INVALID_HANDLE ||
        g_h_atr_ema == INVALID_HANDLE ||
        g_h_ema50_h1 == INVALID_HANDLE ||
        g_h_ema200_h1 == INVALID_HANDLE) {
        Log("CRITICAL: Failed to create indicator handles. Check symbol availability.");
        return INIT_FAILED;
    }

    ZeroMemory(g_pos_state);
    g_pos_state.active = false;

    Log(StringFormat("Warming up POI state from last %d bars...", InpWarmupBars));
    WarmupPOIs();

    MqlRates tmp[];
    ArraySetAsSeries(tmp, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, InpStructureLookback + 20, tmp);

    if (copied > 5) {
        g_structure = DetectStructure(tmp, copied);
        g_current_atr = GetATR();
        g_htf_trend = GetHTFTrend();
        GetDailyLevels(g_pdh, g_pdl);
        GetAsianRange(g_asian_high, g_asian_low);
    }

    g_last_bar_time = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (g_position_info.SelectByIndex(i)) {
            if (g_position_info.Symbol() == _Symbol && g_position_info.Magic() == InpMagicNumber) {
                g_pos_state.active = true;
                g_pos_state.ticket = g_position_info.Ticket();
                g_pos_state.is_long = (g_position_info.PositionType() == POSITION_TYPE_BUY);
                g_pos_state.entry_price = g_position_info.PriceOpen();
                g_pos_state.current_sl = g_position_info.StopLoss();

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

                string comment = g_position_info.Comment();
                if (StringFind(comment, "Nexubot|") == 0) {
                    g_pos_state.strategy_name = StringSubstr(comment, 8);
                } else {
                    g_pos_state.strategy_name = "Unknown";
                }

                Log(StringFormat("Recovered active position tracker for ticket %d", g_pos_state.ticket));
                break;
            }
        }
    }

    Log(StringFormat("Nexubot initialized. HTF Trend: %.1f | ATR: %.5f | PDH: %.5f | PDL: %.5f",
                      g_htf_trend, g_current_atr, g_pdh, g_pdl));
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    if (g_h_atr != INVALID_HANDLE) IndicatorRelease(g_h_atr);
    if (g_h_atr_ema != INVALID_HANDLE) IndicatorRelease(g_h_atr_ema);
    if (g_h_ema50_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema50_h1);
    if (g_h_ema200_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema200_h1);

    ExportStrategyStats();
    ExportDiagnosticStats();

    Log(StringFormat("Nexubot deinitialized. Reason: %d", reason));
}

void OnTick() {
    if (g_pos_state.active) {
        ManagePosition();
    }

    datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
    if (current_bar == g_last_bar_time) return;
    g_last_bar_time = current_bar;

    RunMarketAnalysis();
}