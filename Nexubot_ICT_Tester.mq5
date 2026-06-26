//+------------------------------------------------------------------+
//|                                        Nexubot_ICT_Tester.mq5    |
//|                        Nexubot Systems © 2026                    |
//|                                                                  |
//|  Architecture: Isolated ICT Optimal Trade Entry (OTE) strategy   |
//|  for optimization. Strips out all POI, FVG, and sweep logic to   |
//|  focus purely on deep structural retracements and Fib levels.    |
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
input double          InpRiskPercent        = 2.0;       // Risk per trade (% of balance)
input double          InpMaxLotSize         = 1.0;       // Hard cap on lot size
input double          InpMinRR              = 1.5;       // Min structural R/R before entry
input double          InpMaxRR              = 4.0;       // Hard cap on structural R/R to prevent over-extension
input bool            InpUseDynamicRisk     = true;      // Scale risk by account size tiers

//--- Entry Filters
input group           "==== ENTRY SIGNAL FILTERS ===="
input bool            InpRequireHTFAlign    = true;      // Require H1 trend aligned to signal
input bool            InpRequireBOS         = true;      // Require BOS or CHoCH confirmation
input bool            InpSessionFilter      = true;      // Only trade during active killzones
input int             InpMaxSpreadPoints    = 500;       // Max allowed spread in points (0=off)

//--- OTE Strategy Settings
input group           "==== OTE STRATEGY SETTINGS ===="
input double          InpOTEFibMin          = 0.618;     // Minimum Fib Retracement Level (e.g. 61.8%)
input double          InpOTEFibMax          = 0.786;     // Maximum Fib Retracement Level (e.g. 78.6%)
input double          InpOTEFibSL           = 0.886;     // Fib Level for SL Anchor (e.g. 88.6%)
input double          InpOTEVolRatio        = 1.0;       // Minimum volume ratio for OTE bounce candle
input double          InpOTEATRBuffer       = 0.2;      // SL Buffer applied beyond the SL Fib Anchor (x ATR)

//--- ATR & Volatility
input group           "==== ATR & VOLATILITY ===="
input int             InpATRPeriod          = 14;        // ATR calculation period
input int             InpATREMAPeriod       = 48;        // ATR EMA period (expansion baseline)
input double          InpMinVolExpansion    = 0.7;      // Optimal ATR expansion ratio (full risk)
input double          InpMinVolFloor        = 0.7;      // Absolute minimum expansion ratio (scaled risk floor)
input double          InpSLMultiplierBase   = 1.0;       // Base SL ATR multiplier
input double          InpSLMultiplierHVol   = 1.4;       // SL ATR multiplier for volatile assets
input double          InpMaxSLCapATR        = 2.0;       // Max SL cap (x ATR) — hard ceiling
input double          InpTPMultiplier       = 4.0;       // Base TP ATR multiplier

//--- SMC Structure Settings
input group           "==== SMC STRUCTURE DETECTION ===="
input int             InpPivotLookback      = 5;         // Pivot detection window (bars each side)
input int             InpStructureLookback  = 200;       // Structure detection depth (bars)
input int             InpBOSRecencyBars     = 12;        // Max bars since a BOS/CHoCH to remain "active"
input int             InpSignalCooldownBars = 3;         // Min bars to wait after a trade before allowing a new entry

//--- Session Times  (Server Time)
input group           "==== SESSION TIMES (SERVER TIME) ===="
input int             InpAsianStart         = 2;         // Asian session start hour
input int             InpAsianEnd           = 10;        // Asian session end hour
input int             InpLondonStart        = 9;         // London session start hour
input int             InpLondonEnd          = 18;        // London session end hour
input int             InpNYStart            = 14;        // New York session start hour
input int             InpNYEnd              = 23;        // New York session end hour

//--- Multi-TP Exit Management
input group           "==== MULTI-TP EXIT MANAGEMENT ===="
input double          InpTP1Ratio           = 0.33;      // TP1 = % of full TP3 distance (Trigger for partial close)
input double          InpTP1PartialVol      = 0.50;      // Percentage of original lot size to close at TP1
input double          InpTP2Ratio           = 0.66;      // TP2 = % of full TP3 distance (Trigger for Trail to TP1)
input double          InpBEBufferATR        = 0.15;      // Breakeven buffer above entry (x ATR)
input int             InpMaxTradeMins       = 240;       // Max trade duration (minutes)

//--- Logging & Notifications
input group           "==== NOTIFICATIONS ===="
input bool            InpEnableAlerts       = true;      // Enable MT5 popup alerts
input bool            InpEnableNotify       = true;      // Enable mobile push notifications
input bool            InpVerboseLog         = true;      // Print verbose debug logs
input ulong           InpMagicNumber        = 20260801;  // EA magic number

//==========================================================================
//  SECTION 2: CONSTANTS & STRUCTS
//==========================================================================

#define ZONE_BULL 0
#define ZONE_BEAR 1

#define STRUCT_FLAT 0
#define STRUCT_BULL 1
#define STRUCT_BEAR 2

struct SStructureInfo {
    int    structure;           // STRUCT_BULL, STRUCT_BEAR, or STRUCT_FLAT
    int    bos_dir;             // BOS direction
    int    choch_dir;           // CHoCH direction
    double last_high;           // Last confirmed pivot high price
    double last_low;            // Last confirmed pivot low price
    double prev_high;           // Second-to-last confirmed pivot high
    double prev_low;            // Second-to-last confirmed pivot low
    double pd_array;            // Premium/Discount status (0.0=full discount, 1.0=full premium)
    bool   valid;               // Data is populated and reliable
};

struct SSignal {
    bool   valid;               // Is this a valid signal?
    int    direction;           // ZONE_BULL (long) or ZONE_BEAR (short)
    double suggested_sl;        // Strategy-supplied raw SL level
    string strategy_name;       // Human-readable strategy label
    string diagnostic;          // Introspection reason for failure
};

struct SPositionState {
    bool     active;            // Is this state tracking a live position?
    ulong    ticket;            // MT5 position ticket
    bool     is_long;           // true=BUY, false=SELL
    double   entry_price;       // Price at which trade was entered
    double   initial_volume;    // Volume at trade execution
    double   current_sl;        // Current stop loss level
    double   tp1;               // First take-profit level (breakeven trigger)
    double   tp2;               // Second take-profit level (trail-to-TP1 trigger)
    double   tp3;               // Final take-profit target
    bool     tp1_hit;           // Has TP1 been reached this trade?
    bool     tp2_hit;           // Has TP2 been reached this trade?
    bool     be_set;            // Has stop been moved to breakeven or better?
    double   atr_at_entry;      // ATR value captured at entry
    datetime open_time;         // Time trade was opened
    string   strategy_name;     // The strategy that generated the trade
    bool     timeout_logged;    // Has the timeout warning been logged?
};

struct SSessionInfo {
    bool   is_active;           // Is at least one session currently active?
    string session_name;        // "ASIAN", "LONDON", "NY", or "DEAD"
    double multiplier;          // Confidence multiplier for session quality
    bool   is_london_session;   // True during the entire London session
};

//==========================================================================
//  SECTION 3: GLOBAL STATE
//==========================================================================

CTrade        g_trade;
CPositionInfo g_position_info;

int g_h_atr       = INVALID_HANDLE;
int g_h_atr_ema   = INVALID_HANDLE;
int g_h_ema50_h1  = INVALID_HANDLE;
int g_h_ema200_h1 = INVALID_HANDLE;

SStructureInfo g_structure;
double g_htf_trend   = 0.0;
double g_current_atr = 0.0;
double g_pdh         = 0.0;
double g_pdl         = 0.0;
double g_asian_high  = 0.0;
double g_asian_low   = 0.0;

SPositionState g_pos_state;

datetime g_last_bar_time      = 0;
string   g_last_manage_reason = "";
datetime g_last_spread_log    = 0;

int    g_bars_since_last_signal = 9999;
int    g_bars_since_break       = 9999;
int    g_recent_break_dir       = STRUCT_FLAT;
double g_last_break_level       = 0.0;

string g_volatile_ids[] = {"XAU", "XAG", "BTC", "ETH", "US30", "NAS", "SPX", "UK100", "GER40"};

//==========================================================================
//  SECTION 4: UTILITY FUNCTIONS
//==========================================================================

void Log(const string msg, bool verbose_only = false) {
    if (verbose_only && !InpVerboseLog) return;
    PrintFormat("[Nexubot OTE] %s", msg);
}

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

void PrintThrottledManageLog(string msg) {
    if (msg != g_last_manage_reason) {
        Log(msg, true);
        g_last_manage_reason = msg;
    }
}

double GetATR() {
    if (g_h_atr == INVALID_HANDLE) return 0.0;
    double MIN_ATR_FLOOR = 50.0 * _Point;
    double atr[];
    ArraySetAsSeries(atr, true);
    ResetLastError();
    if (CopyBuffer(g_h_atr, 0, 1, 1, atr) < 1) return MIN_ATR_FLOOR;
    return MathMax(atr[0], MIN_ATR_FLOOR);
}

double GetATRExpansionRatio() {
    if (g_h_atr == INVALID_HANDLE || g_h_atr_ema == INVALID_HANDLE) return 1.0;
    double atr_buf[], ema_buf[];
    ArraySetAsSeries(atr_buf, true);
    ArraySetAsSeries(ema_buf, true);
    if (CopyBuffer(g_h_atr, 0, 1, 1, atr_buf) < 1) return 1.0;
    if (CopyBuffer(g_h_atr_ema, 0, 1, 1, ema_buf) < 1 || ema_buf[0] <= 0) return 1.0;
    return MathMax(0.3, MathMin(3.0, atr_buf[0] / ema_buf[0]));
}

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

double GetVolumeSMA(const MqlRates &rates[], int start, int period) {
    int total = ArraySize(rates);
    if (total < start + period) return 1.0;
    double sum = 0.0;
    for (int i = start; i < start + period; i++) sum += (double)rates[i].tick_volume;
    return MathMax(1.0, sum / period);
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

    info.is_active         = is_asian || is_london || is_ny;
    info.is_london_session = is_london;

    if      (is_ny)     { info.session_name = "NY";     info.multiplier = 1.05; }
    else if (is_london) { info.session_name = "LONDON"; info.multiplier = 1.03; }
    else if (is_asian)  { info.session_name = "ASIAN";  info.multiplier = 0.97; }
    else                { info.session_name = "DEAD";   info.multiplier = 0.90; }

    return info;
}

//==========================================================================
//  SECTION 5: MARKET STRUCTURE ANALYSIS
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
        bool is_asian_bar = (InpAsianStart < InpAsianEnd) ? (bar_dt.hour >= InpAsianStart && bar_dt.hour < InpAsianEnd) : (bar_dt.hour >= InpAsianStart || bar_dt.hour < InpAsianEnd);
        if (is_asian_bar) {
            asian_high = MathMax(asian_high, rates[i].high);
            asian_low  = MathMin(asian_low,  rates[i].low);
        }
    }
    if (asian_low == DBL_MAX) { asian_high = 0.0; asian_low = 0.0; }
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

//==========================================================================
//  SECTION 6: ISOLATED OTE STRATEGY LOGIC
//==========================================================================

/// @brief STRATEGY: ICT Optimal Trade Entry (OTE Fibonacci)
/// Enters at the deep Fibonacci retracement (user-defined, default 61.8% - 78.6%)
/// of the last structural swing.
SSignal Strategy_ICT_OTE(const MqlRates &curr, double atr) {
    SSignal sig;
    ZeroMemory(sig);
    sig.valid = false;

    // 1. Structure validation
    if (!g_structure.valid || g_structure.last_high <= 0 || g_structure.last_low <= 0) {
        sig.diagnostic = "Structure invalid/no range";
        return sig;
    }

    double range = g_structure.last_high - g_structure.last_low;
    if (range <= 0) {
        sig.diagnostic = "Invalid structure range";
        return sig;
    }

    // 2. Volume confirmation for OTE entries
    MqlRates rates_check[];
    ArraySetAsSeries(rates_check, true);
    double vol_sma = 1.0;
    if (CopyRates(_Symbol, PERIOD_M5, 1, 25, rates_check) == 25) {
        vol_sma = GetVolumeSMA(rates_check, 1, 20);
    }

    double vol_ratio = (double)curr.tick_volume / vol_sma;
    if (vol_ratio < InpOTEVolRatio) {
        sig.diagnostic = "Volume too low for OTE bounce";
        return sig;
    }

    double close_price = curr.close;
    double atr_buf = atr * InpOTEATRBuffer;

    // --- Bullish OTE Setup ---
    if (g_structure.structure == STRUCT_BULL) {
        if (InpRequireHTFAlign && g_htf_trend != 1.0) {
            sig.diagnostic = "OTE blocked: HTF trend is not Bullish";
            return sig;
        }

        // Bullish Fib measured from last_low (0) to last_high (1)
        double fib_min = g_structure.last_high - range * InpOTEFibMin;
        double fib_max = g_structure.last_high - range * InpOTEFibMax;
        double fib_sl  = g_structure.last_high - range * InpOTEFibSL;

        // Note: fib_min is numerically higher than fib_max
        if (close_price <= fib_min && close_price >= fib_max && curr.close > curr.open) {
            sig.valid = true;
            sig.direction = ZONE_BULL;
            sig.strategy_name = "ICT OTE (Bullish)";

            // Tighten SL to the deeper of the bounce candle low or the SL Fib level
            double sl_anchor = MathMin(curr.low, fib_sl);
            sig.suggested_sl = sl_anchor - atr_buf;
            return sig;
        }
        sig.diagnostic = "Price outside Bullish OTE zone or no rejection";
    }
    // --- Bearish OTE Setup ---
    else if (g_structure.structure == STRUCT_BEAR) {
        if (InpRequireHTFAlign && g_htf_trend != -1.0) {
            sig.diagnostic = "OTE blocked: HTF trend is not Bearish";
            return sig;
        }

        // Bearish Fib measured from last_high (0) to last_low (1)
        double fib_min = g_structure.last_low + range * InpOTEFibMin;
        double fib_max = g_structure.last_low + range * InpOTEFibMax;
        double fib_sl  = g_structure.last_low + range * InpOTEFibSL;

        // Note: fib_min is numerically lower than fib_max
        if (close_price >= fib_min && close_price <= fib_max && curr.close < curr.open) {
            sig.valid = true;
            sig.direction = ZONE_BEAR;
            sig.strategy_name = "ICT OTE (Bearish)";

            // Tighten SL to the higher of the bounce candle high or the SL Fib level
            double sl_anchor = MathMax(curr.high, fib_sl);
            sig.suggested_sl = sl_anchor + atr_buf;
            return sig;
        }
        sig.diagnostic = "Price outside Bearish OTE zone or no rejection";
    } else {
        sig.diagnostic = "Structure is flat (No OTE possible)";
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

double CalculateLotSize(double entry_price, double sl_price, ENUM_ORDER_TYPE order_type, double session_multiplier = 1.0) {
    double balance          = AccountInfoDouble(ACCOUNT_BALANCE);
    string currency         = AccountInfoString(ACCOUNT_CURRENCY);
    double applied_risk_pct = GetRiskCap(balance, currency);
    double risk_amount      = balance * (applied_risk_pct / 100.0) * session_multiplier;

    double tick_value       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size        = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double sl_distance      = MathAbs(entry_price - sl_price);

    if (sl_distance <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0)
        return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double loss_per_lot     = (sl_distance / tick_size) * tick_value;
    double lot_size         = risk_amount / loss_per_lot;
    double margin_required  = 0.0;

    if (!OrderCalcMargin(order_type, _Symbol, lot_size, entry_price, margin_required)) {
        lot_size = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    } else {
        double free_margin        = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
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

    if (signal.suggested_sl > 0.0) {
        double suggested_dist = MathAbs(signal.suggested_sl - entry);
        bool   correct_side   = (is_long && signal.suggested_sl < entry) || (!is_long && signal.suggested_sl > entry);
        if (correct_side && suggested_dist > atr * 0.35 && suggested_dist <= atr * InpMaxSLCapATR) {
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
    double min_tp_dist  = sl_dist * InpMinRR;

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

bool ExecuteTrade(const SSignal &signal, double sl, double tp1, double tp2, double tp3, double lots, double atr) {
    bool   is_long = (signal.direction == ZONE_BULL);
    double entry   = is_long ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    entry = NormalizeDouble(entry, digits);
    sl    = NormalizeDouble(sl,    digits);
    tp3   = NormalizeDouble(tp3,   digits);

    bool success = is_long
        ? g_trade.Buy(lots,  _Symbol, entry, sl, tp3, StringFormat("NexubotOTE|%s", signal.strategy_name))
        : g_trade.Sell(lots, _Symbol, entry, sl, tp3, StringFormat("NexubotOTE|%s", signal.strategy_name));

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

    Log(StringFormat("ENTRY: %s | SL: %.5f | TP3: %.5f | Lots: %.2f", signal.strategy_name, sl, tp3, lots));
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

void ManagePosition() {
    if (!IsPositionOpen()) {
        if (g_pos_state.active) { ZeroMemory(g_pos_state); g_pos_state.active = false; }
        return;
    }

    int elapsed_mins = (int)((TimeCurrent() - g_pos_state.open_time) / 60);
    if (elapsed_mins >= InpMaxTradeMins) {
        if (!g_pos_state.timeout_logged) {
            Log(StringFormat("TIMEOUT: Forcing close after %d min (max %d min). Strategy: %s",
                              elapsed_mins, InpMaxTradeMins, g_pos_state.strategy_name));
            g_pos_state.timeout_logged = true;
            g_trade.PositionClose(g_pos_state.ticket);
        }
        return;
    }

    double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double curr_price = g_pos_state.is_long ? bid : ask;
    int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // --- TP1: Partial close + move SL to breakeven ---
    if (!g_pos_state.tp1_hit) {
        bool hit_tp1 = g_pos_state.is_long ? (curr_price >= g_pos_state.tp1) : (curr_price <= g_pos_state.tp1);

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
        bool hit_tp2 = g_pos_state.is_long ? (curr_price >= g_pos_state.tp2) : (curr_price <= g_pos_state.tp2);
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

void RunMarketAnalysis() {
    g_bars_since_last_signal++;

    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 600, rates);
    if (copied < 50) return;

    // Refresh context
    g_htf_trend   = GetHTFTrend();
    g_current_atr = GetATR();
    GetDailyLevels(g_pdh, g_pdl);
    GetAsianRange(g_asian_high, g_asian_low);

    if (g_current_atr <= 0.0) return;

    g_structure = DetectStructure(rates, copied);
    if (!g_structure.valid) return;

    // Update BOS/CHoCH counters
    bool has_structure_break = (g_structure.bos_dir != STRUCT_FLAT) || (g_structure.choch_dir != STRUCT_FLAT);

    if (has_structure_break) {
        int new_break_dir = (g_structure.bos_dir != STRUCT_FLAT) ? g_structure.bos_dir : g_structure.choch_dir;
        double break_ref_level = (new_break_dir == STRUCT_BULL) ? g_structure.last_high : g_structure.last_low;

        bool is_new_break = (new_break_dir != g_recent_break_dir) ||
                            (g_last_break_level <= 0.0) ||
                            (MathAbs(break_ref_level - g_last_break_level) > g_current_atr * 0.15);

        if (is_new_break) {
            g_recent_break_dir = new_break_dir;
            g_last_break_level = break_ref_level;
            g_bars_since_break = 0;
        } else {
            g_bars_since_break++;
        }
    } else {
        g_bars_since_break++;
    }

    // --- Entry Filter Gates ---
    SSessionInfo session = GetSessionInfo();
    if (InpSessionFilter && !session.is_active) return;
    if (IsPositionOpen()) return;
    if (InpSignalCooldownBars > 0 && g_bars_since_last_signal < InpSignalCooldownBars) return;

    if (InpMaxSpreadPoints > 0) {
        double spread_pts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
        if (spread_pts > (double)InpMaxSpreadPoints) {
            PrintThrottledSkipReason(StringFormat("Spread %.0f pts exceeds max %d. Skipping.", spread_pts, InpMaxSpreadPoints));
            return;
        }
    }

    double atr_expansion = GetATRExpansionRatio();
    if (atr_expansion < InpMinVolFloor) return;
    if (atr_expansion < InpMinVolExpansion) {
        double vol_confidence = MathMax(0.25, MathMin(1.0, (atr_expansion - InpMinVolFloor) / (InpMinVolExpansion - InpMinVolFloor)));
        session.multiplier *= vol_confidence;
    }

    if (InpRequireHTFAlign && g_htf_trend == 0.0) return;
    if (InpRequireBOS && g_bars_since_break > InpBOSRecencyBars) return;

    // --- Strategy Route ---
    double pd = g_structure.pd_array;
    bool allow_long  = (pd <= 0.60);
    bool allow_short = (pd >= 0.40);

    SSignal signal = Strategy_ICT_OTE(rates[1], g_current_atr);
    if (!signal.valid) {
        PrintThrottledSkipReason(StringFormat("OTE rejected: %s", signal.diagnostic));
        return;
    }

    if (signal.direction == ZONE_BULL && !allow_long)  return;
    if (signal.direction == ZONE_BEAR && !allow_short) return;

    // --- Execution ---
    double entry = (signal.direction == ZONE_BULL) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl_price = 0.0, tp1 = 0.0, tp2 = 0.0, tp3 = 0.0;

    if (!CalculateSLTP(signal, entry, g_current_atr, sl_price, tp1, tp2, tp3)) return;

    ENUM_ORDER_TYPE order_type = (signal.direction == ZONE_BULL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    double lots = CalculateLotSize(entry, sl_price, order_type, session.multiplier);

    if (lots > 0.0) {
        if (ExecuteTrade(signal, sl_price, tp1, tp2, tp3, lots, g_current_atr)) {
            g_bars_since_last_signal = 0;
            Log(StringFormat("SIGNAL: %s | %s | BOS %d bars | HTF %.0f | PD %.2f",
                              signal.direction == ZONE_BULL ? "LONG" : "SHORT",
                              signal.strategy_name,
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

    ZeroMemory(g_pos_state);
    g_pos_state.active = false;
    g_last_break_level = 0.0;

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
    Log(StringFormat("Nexubot ICT Tester v1.00 initialised | Symbol: %s | Magic: %d", _Symbol, (int)InpMagicNumber));

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    if (g_h_atr       != INVALID_HANDLE) IndicatorRelease(g_h_atr);
    if (g_h_atr_ema   != INVALID_HANDLE) IndicatorRelease(g_h_atr_ema);
    if (g_h_ema50_h1  != INVALID_HANDLE) IndicatorRelease(g_h_ema50_h1);
    if (g_h_ema200_h1 != INVALID_HANDLE) IndicatorRelease(g_h_ema200_h1);
}

void OnTick() {
    if (g_pos_state.active) ManagePosition();

    datetime current_bar = iTime(_Symbol, PERIOD_M5, 0);
    if (current_bar == g_last_bar_time) return;
    g_last_bar_time = current_bar;

    RunMarketAnalysis();
}