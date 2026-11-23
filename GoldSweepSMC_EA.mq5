//+------------------------------------------------------------------+
//| GoldSweepSMC_EA.mq5 — Gold Sweep SMC EA                          |
//| Copyright 2026, Fazla Rabbi                                      |
//| https://github.com/connectfazla/gold-sweep-smc-mt5               |
//| License: Mozilla Public License 2.0                              |
//|                                                                  |
//| MetaTrader 5 port of Fazla Rabbi's Pine Script v6 strategy       |
//| "Gold Sweep–CHoCH SMC Strategy" for XAUUSD.                      |
//|                                                                  |
//| Bar-close logic, same order as the Pine script. Signals are      |
//| evaluated on the last closed bar and filled at market on the     |
//| next tick (Pine: process_orders_on_close).                       |
//|                                                                  |
//| Exits: one position, server SL, server TP = TP3 (or TP2 when the |
//| size cannot be split in three). TP1/TP2 legs are closed by the   |
//| EA on the tick that touches them. Works on hedging and netting.  |
//|                                                                  |
//| Not ported: chart drawings, the status table, the VWAP trend     |
//| method. Exit state is in memory: after an EA restart an open     |
//| trade keeps its server SL/TP but loses partials/BE/trail.        |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Fazla Rabbi"
#property link        "https://github.com/connectfazla/gold-sweep-smc-mt5"
#property version     "1.00"
#property description "Gold Sweep SMC EA by Fazla Rabbi."
#property description "Liquidity sweep -> CHoCH -> BOS -> FVG/order-block retest entries for XAUUSD,"
#property description "with three-leg exits, breakeven, structure trail and daily risk limits."
#include <Trade/Trade.mqh>

#define NA  EMPTY_VALUE
#define NAI INT_MIN

enum ETrendMethod { TM_EMA = 0,   // EMA
                    TM_SWING = 1  // Swing structure
                  };
enum ESizing      { SZ_PERCENT = 0, // Percent of equity per trade
                    SZ_CASH = 1,    // Fixed cash risk per trade
                    SZ_LOTS = 2     // Fixed lot size
                  };
enum EPdMode      { PD_HALF = 0,  // Discount/Premium (50%)
                    PD_OTE = 1    // OTE zone
                  };
enum EPdRef       { PDR_MID = 0,   // Zone midpoint
                    PDR_WICK = 1,  // Retest candle low/high
                    PDR_CLOSE = 2  // Close
                  };
enum EZone        { Z_FVG = 0,    // FVG only
                    Z_OB = 1,     // Order Block only
                    Z_EITHER = 2, // FVG or Order Block
                    Z_BOTH = 3    // FVG and Order Block
                  };

input group "Timeframes & Trend"
input ENUM_TIMEFRAMES InpTrendTF        = PERIOD_H4;  // Trend confirmation timeframe
input ENUM_TIMEFRAMES InpLiqTF          = PERIOD_M15; // Major liquidity timeframe
input ENUM_TIMEFRAMES InpSecTF          = PERIOD_H1;  // Secondary trend timeframe
input ETrendMethod    InpTrendMethod    = TM_EMA;     // Trend method
input int             InpTrendEmaLen    = 50;         // Trend EMA length
input int             InpTrendPivotLen  = 3;          // Trend swing pivot strength
input bool            InpUseTrend       = true;       // Require primary trend alignment
input bool            InpUseSecTrend    = true;       // Require secondary trend alignment

input group "Liquidity & Sweeps"
input int    InpPivotLen        = 4;     // Execution swing pivot strength
input int    InpHtfPivotLen     = 4;     // Major swing pivot strength
input double InpEqualTolAtr     = 0.15;  // Equal-high/low tolerance (ATR)
input int    InpSetupExpiry     = 25;    // Setup validity until BOS (bars)
input int    InpPostBosExpiry   = 15;    // Extra validity after BOS (bars)
input bool   InpDynamicBos      = true;  // Use latest post-sweep swing for BOS
input bool   InpReqMtfSweep     = true;  // Require confirmed major-timeframe sweep
input int    InpMtfWindow       = 40;    // MTF sweep look-back at setup creation (bars)
input bool   InpUsePrevDay      = true;  // Use previous-day high/low as liquidity

input group "Sessions (New York time)"
input int  InpServerMinusNY   = 7;     // Server time minus New York time (hours)
input int  InpAsiaStart       = 2000;  // Asia start HHMM
input int  InpAsiaEnd         = 0;     // Asia end HHMM
input int  InpLondonStart     = 200;   // London start HHMM
input int  InpLondonEnd       = 500;   // London end HHMM
input int  InpNyStart         = 700;   // New York AM start HHMM
input int  InpNyEnd           = 1000;  // New York AM end HHMM
input bool InpSessionSweeps   = true;  // Use completed session levels for sweeps
input bool InpSessionFilter   = true;  // Restrict entries to selected sessions
input bool InpAllowAsia       = false; // Allow entries during Asia
input bool InpAllowLondon     = true;  // Allow entries during London
input bool InpAllowNy         = true;  // Allow entries during New York AM

input group "Stops, Targets & Sizing"
input double  InpStopBufAtr     = 0.10;  // Stop buffer beyond sweep (ATR)
input double  InpMinStopAtr     = 0.5;   // Minimum stop distance (ATR, 0 = off)
input double  InpMaxStopAtr     = 5.0;   // Maximum stop distance (ATR, 0 = off)
input double  InpFallbackR      = 3.0;   // TP3 fallback (R)
input double  InpMaxTp3R        = 6.0;   // TP3 cap (R)
input ESizing InpSizing         = SZ_PERCENT; // How risk per trade is set
input double  InpRiskPct        = 0.5;   // Risk per trade (% of equity)
input double  InpRiskCash       = 5000;  // Risk per trade (account currency)
input double  InpFixedLots      = 0.01;  // Fixed lot size
input bool    InpBreakeven      = true;  // Move stop to breakeven after TP1
input bool    InpTrail          = true;  // Trail stop behind swings after TP2
input double  InpTrailBufAtr    = 0.10;  // Trail buffer beyond swing (ATR)
input int     InpMaxBarsInTrade = 0;     // Time stop: bars allowed before TP1 (0 = off)

input group "Filters & Daily Limits"
input bool   InpRoomFilter     = true;  // Require room to opposing major liquidity
input double InpMinRoomR       = 1.5;   // Minimum room to opposing liquidity (R)
input bool   InpAllowReversal  = false; // Allow a signal to reverse an open position
input int    InpMaxTradesDay   = 3;     // Max entries per trading day (0 = unlimited)
input double InpDailyLossPct   = 2.0;   // Daily loss limit (% of day-start equity, 0 = off)
input int    InpRolloverHour   = 17;    // Trading-day rollover hour (NY time)

input group "Retest Entries"
input int    InpObLookback      = 20;    // Order-block search bars
input bool   InpReqRetestCandle = true;  // Require directional retest candle
input bool   InpReqRetestBreak  = true;  // Confirm retest by breaking its candle
input int    InpConfirmBars     = 3;     // Bars allowed for confirmation
input double InpMaxChaseAtr     = 0.5;   // Maximum confirmation chase (ATR)
input double InpMinConfBodyAtr  = 0.2;   // Minimum confirmation body (ATR)
input double InpMinConfBodyPct  = 50.0;  // Minimum confirmation body (% of range)
input double InpMinFvgAtr       = 0.3;   // Minimum entry FVG size (ATR)

input group "SMC Entry Logic"
input bool    InpUseChoch      = true;     // Require CHoCH / MSS
input bool    InpUseDisp       = true;     // Require displacement on structure breaks
input double  InpDispBodyAtr   = 0.8;      // Displacement min body (x ATR)
input double  InpDispBodyPct   = 60.0;     // Displacement min body (% of range)
input bool    InpUsePD         = true;     // Require discount (longs) / premium (shorts)
input EPdMode InpPdMode        = PD_HALF;  // Premium/Discount mode
input EPdRef  InpPdRef         = PDR_MID;  // Premium/Discount reference price
input double  InpOteStart      = 0.62;     // OTE retracement start
input double  InpOteEnd        = 0.79;     // OTE retracement end
input int     InpMinRetestBars = 3;        // Min bars from structure break to retest
input bool    InpReqRejection  = true;     // Require wick-in, close-out rejection
input EZone   InpEntryZone     = Z_EITHER; // Entry zone

input group "Execution"
input long InpMagic      = 260523;  // Magic number
input int  InpWarmupBars = 3000;    // History bars replayed at start
input int  InpSlippage   = 30;      // Max slippage (points)

//--- one side's setup (Pine: activeBull*/activeBear*/bullRej*/bearRej*)
struct Setup
  {
   int    sweepBar;
   double sweepExt, stop, sweepLevel;
   double bosLevel;
   int    bosPivotBar, bosBar;
   bool   bosConf;
   double fvgTop, fvgBot;
   int    fvgBar;
   double chochLevel;
   int    chochBar;
   bool   chochConf;
   int    structBar;
   double rangeExt;
   double obTop, obBot;
   int    obBar;
   bool   mtfOk;
   int    rejBar;
   double rejPx;
   bool   rejFvg, rejOb;
   int    rejFvgBar, rejObBar;
  };

CTrade trade;
Setup  B, S;
int    g_bar = 0;
bool   g_ready = false;
datetime g_curBarTime = 0, g_lastProcTime = 0;
double g_tick, g_step, g_minVol, g_maxVol;
int    g_emaTrend = INVALID_HANDLE, g_emaSec = INVALID_HANDLE;

// ATR(14), Pine RMA
double g_atr = NA, g_trSum = 0;
int    g_trN = 0;
// chart-TF pivots (latest, previous, older)
double g_ph0 = NA, g_ph1 = NA, g_ph2 = NA, g_pl0 = NA, g_pl1 = NA, g_pl2 = NA;
int    g_ph0b = NAI, g_ph1b = NAI, g_ph2b = NAI, g_pl0b = NAI, g_pl1b = NAI, g_pl2b = NAI;
// sessions
bool   g_inA = false, g_inL = false, g_inN = false;
double g_aRH = NA, g_aRL = NA, g_lRH = NA, g_lRL = NA, g_nRH = NA, g_nRL = NA;
double g_aCH = NA, g_aCL = NA, g_lCH = NA, g_lCL = NA, g_nCH = NA, g_nCL = NA;
// daily limits
int    g_dayKey = -1, g_tradesToday = 0;
double g_dayStartEq = NA;
// MTF
datetime g_liqCacheT = 0, g_liqBarOpen = 0;
double g_swH = NA, g_swL = NA, g_mtfBullExt = NA, g_mtfBearExt = NA;
bool   g_mtfBullRaw = false, g_mtfBearRaw = false;
int    g_lastMtfBullBar = NAI, g_lastMtfBearBar = NAI;
datetime g_trendCacheT[2] = {0, 0};
int    g_trendCacheV[2] = {0, 0};
// liquidity levels used for targets at entry
double g_lvlLong[6], g_lvlShort[6];
// open trade
int    g_posDir = 0;
ulong  g_ticket = 0;
double g_open = NA, g_stop = NA, g_tp1 = NA, g_tp2 = NA, g_tp3 = NA, g_legQty = 0;
bool   g_canSplit = false, g_tp1Hit = false, g_tp2Hit = false;
int    g_entryBar = NAI;

//+------------------------------------------------------------------+
bool   isna(const double v)  { return v == NA; }
double nz(const double v, const double d) { return isna(v) ? d : v; }
double MinNa(const double a, const double b) { return isna(a) ? b : MathMin(a, b); }
double MaxNa(const double a, const double b) { return isna(a) ? b : MathMax(a, b); }
double Px(const double p) { return NormalizeDouble(MathRound(p / g_tick) * g_tick, _Digits); }
bool   SweptLow(const double lvl, const double l, const double c, const double c1)  { return !isna(lvl) && l < lvl && c > lvl && c1 >= lvl; }
bool   SweptHigh(const double lvl, const double h, const double c, const double c1) { return !isna(lvl) && h > lvl && c < lvl && c1 <= lvl; }

void ResetSetup(Setup &x)
  {
   x.sweepBar = NAI; x.sweepExt = NA; x.stop = NA; x.sweepLevel = NA;
   x.bosLevel = NA; x.bosPivotBar = NAI; x.bosBar = NAI; x.bosConf = false;
   x.fvgTop = NA; x.fvgBot = NA; x.fvgBar = NAI;
   x.chochLevel = NA; x.chochBar = NAI; x.chochConf = false;
   x.structBar = NAI; x.rangeExt = NA;
   x.obTop = NA; x.obBot = NA; x.obBar = NAI;
   x.mtfOk = false;
   x.rejBar = NAI; x.rejPx = NA; x.rejFvg = false; x.rejOb = false; x.rejFvgBar = NAI; x.rejObBar = NAI;
  }

// Pine ta.pivothigh/pivotlow with strict inequality on both sides (same rule as the Python port).
bool IsPivot(const ENUM_TIMEFRAMES tf, const int c, const int len, const bool high)
  {
   if(c - len < 0) return false;
   double v = high ? iHigh(_Symbol, tf, c) : iLow(_Symbol, tf, c);
   if(v == 0) return false;
   for(int j = c - len; j <= c + len; j++)
     {
      if(j == c) continue;
      double x = high ? iHigh(_Symbol, tf, j) : iLow(_Symbol, tf, j);
      if(x == 0) return false;
      if(high ? !(v > x) : !(v < x)) return false;
     }
   return true;
  }

// The `need` most recent pivots already confirmed as of bar k on tf (pivot centre shift >= k+len).
// Pine: ta.valuewhen(not na(pivot), pivot, n) evaluated on that bar.
int FindPivots(const ENUM_TIMEFRAMES tf, const int k, const int len, const bool high, const int need, double &val[])
  {
   int n = 0, bars = iBars(_Symbol, tf);
   for(int c = k + len; c < k + len + 500 && c + len < bars && n < need; c++)
      if(IsPivot(tf, c, len, high))
         val[n++] = high ? iHigh(_Symbol, tf, c) : iLow(_Symbol, tf, c);
   return n;
  }

double NearestAbove(const double ref, const double &lv[])
  {
   double best = NA;
   for(int i = 0; i < ArraySize(lv); i++)
      if(!isna(lv[i]) && lv[i] > ref && (isna(best) || lv[i] < best)) best = lv[i];
   return best;
  }

double NearestBelow(const double ref, const double &lv[])
  {
   double best = NA;
   for(int i = 0; i < ArraySize(lv); i++)
      if(!isna(lv[i]) && lv[i] < ref && (isna(best) || lv[i] > best)) best = lv[i];
   return best;
  }

//--- targets (Pine f_structuralTarget1/2, f_tp3)
double T1Long(double e, double r, const double &lv[])  { double mn = e + r, mx = e + 1.75 * r; double c = NearestAbove(mn, lv); return (!isna(c) && c <= mx) ? c : mn; }
double T1Short(double e, double r, const double &lv[]) { double mx = e - r, mn = e - 1.75 * r; double c = NearestBelow(mx, lv); return (!isna(c) && c >= mn) ? c : mx; }
double T2Long(double e, double r, double t1, const double &lv[])
  { double mn = MathMax(e + 2.0 * r, t1 + 0.25 * r), mx = e + MathMax(2.1, InpMaxTp3R - 0.25) * r; double c = NearestAbove(mn, lv); return (!isna(c) && c <= mx) ? c : mn; }
double T2Short(double e, double r, double t1, const double &lv[])
  { double mx = MathMin(e - 2.0 * r, t1 - 0.25 * r), mn = e - MathMax(2.1, InpMaxTp3R - 0.25) * r; double c = NearestBelow(mx, lv); return (!isna(c) && c >= mn) ? c : mx; }
double T3Long(double e, double r, double t2, const double &lv[])
  { double q = NearestAbove(t2, lv); double cap = e + MathMax(InpMaxTp3R, InpFallbackR) * r; return MathMin(isna(q) ? e + InpFallbackR * r : q, cap); }
double T3Short(double e, double r, double t2, const double &lv[])
  { double q = NearestBelow(t2, lv); double cap = e - MathMax(InpMaxTp3R, InpFallbackR) * r; return MathMax(isna(q) ? e - InpFallbackR * r : q, cap); }

double LotSize(const double entry, const double stop)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskPerLot = MathAbs(entry - stop) / g_tick * tv;
   double budget = InpSizing == SZ_PERCENT ? MathMax(AccountInfoDouble(ACCOUNT_EQUITY), 0.0) * InpRiskPct / 100.0 : InpRiskCash;
   double raw = InpSizing == SZ_LOTS ? InpFixedLots : (riskPerLot > 0 ? budget / riskPerLot : 0);
   double lots = MathFloor(raw / g_step + 1e-9) * g_step;
   if(lots < g_step || lots < g_minVol) return 0;
   return MathMin(lots, g_maxVol);
  }

bool InSession(const int m, const int startHHMM, const int endHHMM)
  {
   int s = startHHMM / 100 * 60 + startHHMM % 100, e = endHHMM / 100 * 60 + endHHMM % 100;
   return s < e ? (m >= s && m < e) : (m >= s || m < e);
  }

// Last completed bar of tf as seen from chart bar time t (Pine: request.security(..., expr[1], lookahead_on)).
int PrevHtfShift(const ENUM_TIMEFRAMES tf, const datetime t)
  {
   int k = iBarShift(_Symbol, tf, t, false);
   return k < 0 ? -1 : k + 1;
  }

int TrendDir(const int idx, const ENUM_TIMEFRAMES tf, const int handle, const datetime t)
  {
   int k = PrevHtfShift(tf, t);
   if(k < 0) return 0;
   datetime kt = iTime(_Symbol, tf, k);
   if(kt == g_trendCacheT[idx]) return g_trendCacheV[idx];
   int dir = 0;
   double cl = iClose(_Symbol, tf, k);
   if(InpTrendMethod == TM_EMA)
     {
      double e[];
      if(CopyBuffer(handle, 0, k, 2, e) == 2)            // e[0] = bar k+1, e[1] = bar k
         dir = (cl > e[1] && e[1] > e[0]) ? 1 : (cl < e[1] && e[1] < e[0]) ? -1 : 0;
      else
         return 0;                                       // not cached: retry next bar
     }
   else
     {
      double hv[2], lv[2];
      if(FindPivots(tf, k, InpTrendPivotLen, true, 2, hv) == 2 && FindPivots(tf, k, InpTrendPivotLen, false, 2, lv) == 2)
         dir = (hv[0] > hv[1] && lv[0] > lv[1] && cl > lv[0]) ? 1 : (hv[0] < hv[1] && lv[0] < lv[1] && cl < hv[0]) ? -1 : 0;
     }
   g_trendCacheT[idx] = kt;
   g_trendCacheV[idx] = dir;
   return dir;
  }

// Major swing high/low and confirmed major-TF sweeps of the last completed LiqTF bar.
void UpdateLiquidity(const datetime t)
  {
   int k = PrevHtfShift(InpLiqTF, t);
   if(k < 0) { g_swH = NA; g_swL = NA; g_mtfBullRaw = false; g_mtfBearRaw = false; return; }
   datetime kt = iTime(_Symbol, InpLiqTF, k);
   if(kt == g_liqCacheT) return;
   g_liqCacheT = kt;
   double v[1];
   g_swH = FindPivots(InpLiqTF, k, InpHtfPivotLen, true, 1, v) == 1 ? v[0] : NA;
   g_swL = FindPivots(InpLiqTF, k, InpHtfPivotLen, false, 1, v) == 1 ? v[0] : NA;
   double hk = iHigh(_Symbol, InpLiqTF, k), lk = iLow(_Symbol, InpLiqTF, k);
   double ck = iClose(_Symbol, InpLiqTF, k), ck1 = iClose(_Symbol, InpLiqTF, k + 1);
   g_mtfBullRaw = SweptLow(g_swL, lk, ck, ck1);
   g_mtfBearRaw = SweptHigh(g_swH, hk, ck, ck1);
   g_mtfBullExt = g_mtfBullRaw ? lk : NA;
   g_mtfBearExt = g_mtfBearRaw ? hk : NA;
  }

//--- position helpers
int PositionDir()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      g_ticket = tk;
      return PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
     }
   return 0;
  }

void ResetPos()
  {
   g_posDir = 0; g_ticket = 0; g_open = NA; g_stop = NA; g_tp1 = NA; g_tp2 = NA; g_tp3 = NA;
   g_legQty = 0; g_canSplit = false; g_tp1Hit = false; g_tp2Hit = false; g_entryBar = NAI;
  }

bool ModifySL(const double sl)
  {
   if(!PositionSelectByTicket(g_ticket)) return false;
   double p = Px(sl);
   if(trade.PositionModify(g_ticket, p, PositionGetDouble(POSITION_TP))) { g_stop = p; return true; }
   return false;
  }

void OpenTrade(const int dir, const double stop, const double lots, const double signalClose, const double &lv[])
  {
   int cur = PositionDir();
   if(cur == -dir && InpAllowReversal) { trade.PositionClose(g_ticket); ResetPos(); }
   double px = dir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(dir > 0 ? px <= stop : px >= stop) { Print("Skip: price already beyond stop"); return; }
   bool ok = dir > 0 ? trade.Buy(lots, _Symbol, 0, Px(stop), 0, "GSMC L") : trade.Sell(lots, _Symbol, 0, Px(stop), 0, "GSMC S");
   if(!ok || PositionDir() != dir) { Print("Entry failed: ", trade.ResultRetcodeDescription()); return; }
   PositionSelectByTicket(g_ticket);
   double fill = PositionGetDouble(POSITION_PRICE_OPEN);
   double e = fill, r = dir > 0 ? fill - stop : stop - fill;
   if(r <= g_tick) { e = signalClose; r = MathAbs(signalClose - stop); }   // Pine keeps the signal-bar targets
   g_posDir = dir; g_open = fill; g_stop = Px(stop); g_entryBar = g_bar;
   g_tp1Hit = false; g_tp2Hit = false;
   if(dir > 0) { g_tp1 = T1Long(e, r, lv);  g_tp2 = T2Long(e, r, g_tp1, lv);  g_tp3 = T3Long(e, r, g_tp2, lv); }
   else        { g_tp1 = T1Short(e, r, lv); g_tp2 = T2Short(e, r, g_tp1, lv); g_tp3 = T3Short(e, r, g_tp2, lv); }
   double vol = PositionGetDouble(POSITION_VOLUME);
   g_legQty = MathFloor(vol * 0.33 / g_step + 1e-9) * g_step;
   g_canSplit = g_legQty >= g_step && g_legQty >= g_minVol && vol - 2.0 * g_legQty >= g_minVol;
   if(!trade.PositionModify(g_ticket, g_stop, Px(g_canSplit ? g_tp3 : g_tp2)))
      Print("TP set failed: ", trade.ResultRetcodeDescription());
   PrintFormat("%s %.2f @ %.2f  SL %.2f  TP1 %.2f  TP2 %.2f  TP3 %.2f  split=%d",
               dir > 0 ? "BUY" : "SELL", vol, fill, g_stop, g_tp1, g_tp2, g_tp3, g_canSplit);
  }

// Tick-level exits: TP1/TP2 legs and breakeven (Pine: strategy.exit limits + high/low through TP flags).
void ManageTicks()
  {
   if(g_posDir == 0) return;
   if(PositionDir() != g_posDir) { ResetPos(); return; }
   double px = g_posDir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(!g_tp1Hit && (g_posDir > 0 ? px >= g_tp1 : px <= g_tp1))
     {
      g_tp1Hit = true;
      if(g_canSplit) trade.PositionClosePartial(g_ticket, g_legQty);
      if(InpBreakeven)
        {
         double be = g_posDir > 0 ? MathMax(g_stop, g_open) : MathMin(g_stop, g_open);
         if(be != g_stop) ModifySL(be);
        }
     }
   if(!g_tp2Hit && (g_posDir > 0 ? px >= g_tp2 : px <= g_tp2))
     {
      g_tp2Hit = true;
      if(g_canSplit) trade.PositionClosePartial(g_ticket, g_legQty);
     }
  }

//+------------------------------------------------------------------+
//| One closed bar at shift s, in Pine statement order.              |
//+------------------------------------------------------------------+
void ProcessBar(const int s, const bool live)
  {
   g_bar++;
   datetime t = iTime(_Symbol, _Period, s);
   g_lastProcTime = t;
   double o = iOpen(_Symbol, _Period, s), h = iHigh(_Symbol, _Period, s), l = iLow(_Symbol, _Period, s), c = iClose(_Symbol, _Period, s);
   double c1 = iClose(_Symbol, _Period, s + 1), h2 = iHigh(_Symbol, _Period, s + 2), l2 = iLow(_Symbol, _Period, s + 2);
   const int P = InpPivotLen;

   //--- higher timeframes
   UpdateLiquidity(t);
   int liqNow = iBarShift(_Symbol, InpLiqTF, t, false);
   datetime liqOpen = liqNow >= 0 ? iTime(_Symbol, InpLiqTF, liqNow) : 0;
   bool newMajorTfBar = liqOpen != g_liqBarOpen;
   g_liqBarOpen = liqOpen;
   bool majorTfValid = PeriodSeconds(InpLiqTF) > PeriodSeconds(_Period);
   bool secValid = PeriodSeconds(InpSecTF) > PeriodSeconds(_Period);
   bool confMtfBull = majorTfValid && newMajorTfBar && g_mtfBullRaw;
   bool confMtfBear = majorTfValid && newMajorTfBar && g_mtfBearRaw;
   int mtfChartBars = majorTfValid ? MathMax(1, (int)MathRound((double)PeriodSeconds(InpLiqTF) / PeriodSeconds(_Period))) : 1;
   int trendDir = TrendDir(0, InpTrendTF, g_emaTrend, t);
   int secDir = TrendDir(1, InpSecTF, g_emaSec, t);
   bool trendBull = (!InpUseTrend || trendDir == 1) && (!InpUseSecTrend || (secValid && secDir == 1));
   bool trendBear = (!InpUseTrend || trendDir == -1) && (!InpUseSecTrend || (secValid && secDir == -1));
   int d1 = iBarShift(_Symbol, PERIOD_D1, t, false);
   double pdh = d1 >= 0 ? iHigh(_Symbol, PERIOD_D1, d1 + 1) : NA;
   double pdl = d1 >= 0 ? iLow(_Symbol, PERIOD_D1, d1 + 1) : NA;
   if(pdh == 0) pdh = NA;
   if(pdl == 0) pdl = NA;

   //--- sessions (bar open time in New York)
   datetime ny = t - InpServerMinusNY * 3600;
   int m = (int)(((long)ny % 86400) / 60);
   bool inA = InSession(m, InpAsiaStart, InpAsiaEnd);
   bool inL = InSession(m, InpLondonStart, InpLondonEnd);
   bool inN = InSession(m, InpNyStart, InpNyEnd);
   if(inA && !g_inA) { g_aRH = h; g_aRL = l; } else if(inA) { g_aRH = MathMax(nz(g_aRH, h), h); g_aRL = MathMin(nz(g_aRL, l), l); }
   if(!inA && g_inA) { g_aCH = g_aRH; g_aCL = g_aRL; }
   if(inL && !g_inL) { g_lRH = h; g_lRL = l; } else if(inL) { g_lRH = MathMax(nz(g_lRH, h), h); g_lRL = MathMin(nz(g_lRL, l), l); }
   if(!inL && g_inL) { g_lCH = g_lRH; g_lCL = g_lRL; }
   if(inN && !g_inN) { g_nRH = h; g_nRL = l; } else if(inN) { g_nRH = MathMax(nz(g_nRH, h), h); g_nRL = MathMin(nz(g_nRL, l), l); }
   if(!inN && g_inN) { g_nCH = g_nRH; g_nCL = g_nRL; }
   g_inA = inA; g_inL = inL; g_inN = inN;
   bool sessPass = !InpSessionFilter || (InpAllowAsia && inA) || (InpAllowLondon && inL) || (InpAllowNy && inN);

   //--- daily limits (trading day rolls at InpRolloverHour NY)
   MqlDateTime dt;
   TimeToStruct(ny + (24 - InpRolloverHour) * 3600, dt);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dt.day != g_dayKey || isna(g_dayStartEq)) { g_dayKey = dt.day; g_dayStartEq = eq; g_tradesToday = 0; }
   bool lossBreached = InpDailyLossPct > 0 && eq < g_dayStartEq * (1.0 - InpDailyLossPct / 100.0);
   bool dailyOk = (InpMaxTradesDay == 0 || g_tradesToday < InpMaxTradesDay) && !lossBreached;

   //--- ATR(14) RMA
   double tr = MathMax(h - l, MathMax(MathAbs(h - c1), MathAbs(l - c1)));
   if(g_trN < 14) { g_trSum += tr; g_trN++; if(g_trN == 14) g_atr = g_trSum / 14.0; }
   else g_atr = (g_atr * 13.0 + tr) / 14.0;

   //--- chart-TF pivots
   double phNow = NA, plNow = NA;
   if(IsPivot(_Period, s + P, P, true))
     {
      g_ph2 = g_ph1; g_ph2b = g_ph1b; g_ph1 = g_ph0; g_ph1b = g_ph0b;
      g_ph0 = iHigh(_Symbol, _Period, s + P); g_ph0b = g_bar - P; phNow = g_ph0;
     }
   if(IsPivot(_Period, s + P, P, false))
     {
      g_pl2 = g_pl1; g_pl2b = g_pl1b; g_pl1 = g_pl0; g_pl1b = g_pl0b;
      g_pl0 = iLow(_Symbol, _Period, s + P); g_pl0b = g_bar - P; plNow = g_pl0;
     }
   if(isna(g_atr)) return;
   double atr = g_atr;

   //--- liquidity pools and sweeps
   bool eqH = !isna(g_ph0) && !isna(g_ph1) && MathAbs(g_ph0 - g_ph1) <= atr * InpEqualTolAtr;
   bool eqL = !isna(g_pl0) && !isna(g_pl1) && MathAbs(g_pl0 - g_pl1) <= atr * InpEqualTolAtr;
   double buySide = eqH ? MathMin(g_ph0, g_ph1) : g_ph0;
   double sellSide = eqL ? MathMax(g_pl0, g_pl1) : g_pl0;
   bool localBull = SweptLow(sellSide, l, c, c1), localBear = SweptHigh(buySide, h, c, c1);
   bool majorBull = SweptLow(g_swL, l, c, c1), majorBear = SweptHigh(g_swH, h, c, c1);
   bool aLowSw = SweptLow(g_aCL, l, c, c1), lLowSw = SweptLow(g_lCL, l, c, c1), nLowSw = SweptLow(g_nCL, l, c, c1);
   bool aHighSw = SweptHigh(g_aCH, h, c, c1), lHighSw = SweptHigh(g_lCH, h, c, c1), nHighSw = SweptHigh(g_nCH, h, c, c1);
   bool pdLowSw = InpUsePrevDay && SweptLow(pdl, l, c, c1);
   bool pdHighSw = InpUsePrevDay && SweptHigh(pdh, h, c, c1);
   bool sessBull = InpSessionSweeps && (aLowSw || lLowSw || nLowSw);
   bool sessBear = InpSessionSweeps && (aHighSw || lHighSw || nHighSw);
   double sessBullLvl = NA, sessBearLvl = NA;
   if(aLowSw) sessBullLvl = g_aCL;
   if(lLowSw) sessBullLvl = MaxNa(sessBullLvl, g_lCL);
   if(nLowSw) sessBullLvl = MaxNa(sessBullLvl, g_nCL);
   if(aHighSw) sessBearLvl = g_aCH;
   if(lHighSw) sessBearLvl = MinNa(sessBearLvl, g_lCH);
   if(nHighSw) sessBearLvl = MinNa(sessBearLvl, g_nCH);
   bool bullCand = localBull || majorBull || confMtfBull || sessBull || pdLowSw;
   bool bearCand = localBear || majorBear || confMtfBear || sessBear || pdHighSw;
   bool bullishSweep = bullCand && !bearCand;
   bool bearishSweep = bearCand && !bullCand;
   bool hasMajorBull = majorBull || confMtfBull, hasMajorBear = majorBear || confMtfBear;
   double bullLvl = NA, bearLvl = NA;
   if(localBull) bullLvl = sellSide;
   if(hasMajorBull && !isna(g_swL)) bullLvl = MinNa(bullLvl, g_swL);
   if(sessBull) bullLvl = MinNa(bullLvl, sessBullLvl);
   if(pdLowSw) bullLvl = MinNa(bullLvl, pdl);
   if(localBear) bearLvl = buySide;
   if(hasMajorBear && !isna(g_swH)) bearLvl = MaxNa(bearLvl, g_swH);
   if(sessBear) bearLvl = MaxNa(bearLvl, sessBearLvl);
   if(pdHighSw) bearLvl = MaxNa(bearLvl, pdh);

   //--- pre-sweep structure reference (pivots inside an MTF sweep candle are skipped)
   int cutB = confMtfBull ? g_bar - mtfChartBars : g_bar;
   int cutS = confMtfBear ? g_bar - mtfChartBars : g_bar;
   double preH, preL; int preHb, preLb;
   if(g_ph0b != NAI && g_ph0b <= cutB)      { preH = g_ph0; preHb = g_ph0b; }
   else if(g_ph1b != NAI && g_ph1b <= cutB) { preH = g_ph1; preHb = g_ph1b; }
   else                                     { preH = g_ph2; preHb = g_ph2b; }
   if(g_pl0b != NAI && g_pl0b <= cutS)      { preL = g_pl0; preLb = g_pl0b; }
   else if(g_pl1b != NAI && g_pl1b <= cutS) { preL = g_pl1; preLb = g_pl1b; }
   else                                     { preL = g_pl2; preLb = g_pl2b; }

   //--- setup creation
   if(confMtfBull) g_lastMtfBullBar = g_bar;
   if(confMtfBear) g_lastMtfBearBar = g_bar;
   bool bullRepl = B.sweepBar == NAI || !B.bosConf || (!isna(B.sweepExt) && l < B.sweepExt);
   bool bearRepl = S.sweepBar == NAI || !S.bosConf || (!isna(S.sweepExt) && h > S.sweepExt);
   bool recentMtfBull = g_lastMtfBullBar != NAI && g_bar - g_lastMtfBullBar <= InpMtfWindow;
   bool recentMtfBear = g_lastMtfBearBar != NAI && g_bar - g_lastMtfBearBar <= InpMtfWindow;
   if(bullishSweep && bullRepl)
     {
      ResetSetup(B);
      B.sweepBar = g_bar;
      B.sweepExt = (confMtfBull && !isna(g_mtfBullExt)) ? MathMin(l, g_mtfBullExt) : l;
      B.stop = B.sweepExt - atr * InpStopBufAtr;
      B.sweepLevel = bullLvl;
      B.bosLevel = preH; B.chochLevel = preH; B.bosPivotBar = preHb;
      B.rangeExt = h;
      B.mtfOk = recentMtfBull;
     }
   if(bearishSweep && bearRepl)
     {
      ResetSetup(S);
      S.sweepBar = g_bar;
      S.sweepExt = (confMtfBear && !isna(g_mtfBearExt)) ? MathMax(h, g_mtfBearExt) : h;
      S.stop = S.sweepExt + atr * InpStopBufAtr;
      S.sweepLevel = bearLvl;
      S.bosLevel = preL; S.chochLevel = preL; S.bosPivotBar = preLb;
      S.rangeExt = l;
      S.mtfOk = recentMtfBear;
     }

   //--- expiry / invalidation
   bool bullBroken = B.sweepBar != NAI && g_bar > B.sweepBar && !isna(B.sweepExt) && l < B.sweepExt;
   bool bearBroken = S.sweepBar != NAI && g_bar > S.sweepBar && !isna(S.sweepExt) && h > S.sweepExt;
   bool bullExpired = B.sweepBar != NAI && g_bar - B.sweepBar > InpSetupExpiry && (!B.bosConf || B.bosBar == NAI || g_bar - B.bosBar > InpPostBosExpiry);
   bool bearExpired = S.sweepBar != NAI && g_bar - S.sweepBar > InpSetupExpiry && (!S.bosConf || S.bosBar == NAI || g_bar - S.bosBar > InpPostBosExpiry);
   if(bullBroken || bullExpired) ResetSetup(B);
   if(bearBroken || bearExpired) ResetSetup(S);
   if(confMtfBull && B.sweepBar != NAI) B.mtfOk = true;
   if(confMtfBear && S.sweepBar != NAI) S.mtfOk = true;

   //--- BOS reference: a swing formed after CHoCH (or after the sweep with dynamic BOS)
   if(B.sweepBar != NAI && !B.bosConf && !isna(phNow))
     {
      bool elig = InpUseChoch ? (B.chochConf && g_bar - P > B.chochBar) : (InpDynamicBos && g_bar - P > B.sweepBar);
      if(elig) { B.bosLevel = phNow; B.bosPivotBar = g_bar - P; }
     }
   if(S.sweepBar != NAI && !S.bosConf && !isna(plNow))
     {
      bool elig = InpUseChoch ? (S.chochConf && g_bar - P > S.chochBar) : (InpDynamicBos && g_bar - P > S.sweepBar);
      if(elig) { S.bosLevel = plNow; S.bosPivotBar = g_bar - P; }
     }

   //--- displacement and dealing range
   double body = MathAbs(c - o), rng = h - l;
   bool dispStrong = rng > 0 && body >= atr * InpDispBodyAtr && body / rng * 100.0 >= InpDispBodyPct;
   bool bullDisp = !InpUseDisp || (c > o && dispStrong);
   bool bearDisp = !InpUseDisp || (c < o && dispStrong);
   if(B.sweepBar != NAI && g_bar > B.sweepBar) B.rangeExt = MathMax(nz(B.rangeExt, h), h);
   if(S.sweepBar != NAI && g_bar > S.sweepBar) S.rangeExt = MathMin(nz(S.rangeExt, l), l);

   //--- BOS
   bool bullBos = B.sweepBar != NAI && !B.bosConf && g_bar > B.sweepBar && (!InpUseChoch || (B.chochConf && g_bar > B.chochBar))
                  && !isna(B.bosLevel) && c > B.bosLevel && (InpUseDisp || c1 <= B.bosLevel) && bullDisp;
   bool bearBos = S.sweepBar != NAI && !S.bosConf && g_bar > S.sweepBar && (!InpUseChoch || (S.chochConf && g_bar > S.chochBar))
                  && !isna(S.bosLevel) && c < S.bosLevel && (InpUseDisp || c1 >= S.bosLevel) && bearDisp;
   if(bullBos) { B.bosConf = true; B.bosBar = g_bar; }
   if(bearBos) { S.bosConf = true; S.bosBar = g_bar; }

   //--- CHoCH (break of the pre-sweep swing)
   bool bullChoch = InpUseChoch && B.sweepBar != NAI && !B.chochConf && g_bar > B.sweepBar && !isna(B.chochLevel)
                    && c > B.chochLevel && (InpUseDisp || c1 <= B.chochLevel) && bullDisp;
   bool bearChoch = InpUseChoch && S.sweepBar != NAI && !S.chochConf && g_bar > S.sweepBar && !isna(S.chochLevel)
                    && c < S.chochLevel && (InpUseDisp || c1 >= S.chochLevel) && bearDisp;
   if(bullChoch) { B.chochConf = true; B.chochBar = g_bar; B.bosLevel = NA; B.bosPivotBar = NAI; }
   if(bearChoch) { S.chochConf = true; S.chochBar = g_bar; S.bosLevel = NA; S.bosPivotBar = NAI; }

   //--- order block: last opposite candle of the structure-shifting leg
   if(InpUseChoch ? bullChoch : bullBos)
     {
      int mx = MathMin(InpObLookback, g_bar - B.sweepBar);
      for(int off = 1; off <= mx; off++)
         if(iClose(_Symbol, _Period, s + off) < iOpen(_Symbol, _Period, s + off))
           { B.obTop = iHigh(_Symbol, _Period, s + off); B.obBot = iLow(_Symbol, _Period, s + off); B.obBar = g_bar; break; }
     }
   if(InpUseChoch ? bearChoch : bearBos)
     {
      int mx = MathMin(InpObLookback, g_bar - S.sweepBar);
      for(int off = 1; off <= mx; off++)
         if(iClose(_Symbol, _Period, s + off) > iOpen(_Symbol, _Period, s + off))
           { S.obTop = iHigh(_Symbol, _Period, s + off); S.obBot = iLow(_Symbol, _Period, s + off); S.obBar = g_bar; break; }
     }

   //--- structure confirmation
   if(B.sweepBar != NAI && B.bosConf && (!InpUseChoch || B.chochConf) && (bullBos || bullChoch)) B.structBar = g_bar;
   if(S.sweepBar != NAI && S.bosConf && (!InpUseChoch || S.chochConf) && (bearBos || bearChoch)) S.structBar = g_bar;

   //--- FVG capture (first qualifying gap on/after BOS)
   bool bullFvgForm = l > h2 && (l - h2) >= atr * InpMinFvgAtr;
   bool bearFvgForm = h < l2 && (l2 - h) >= atr * InpMinFvgAtr;
   if(B.bosConf && B.bosBar != NAI && isna(B.fvgTop) && bullFvgForm && g_bar >= B.bosBar && (!InpUseChoch || (B.chochConf && g_bar >= B.chochBar)))
     { B.fvgTop = l; B.fvgBot = h2; B.fvgBar = g_bar; }
   if(S.bosConf && S.bosBar != NAI && isna(S.fvgTop) && bearFvgForm && g_bar >= S.bosBar && (!InpUseChoch || (S.chochConf && g_bar >= S.chochBar)))
     { S.fvgTop = l2; S.fvgBot = h; S.fvgBar = g_bar; }

   //--- mitigation / invalidation
   if(B.fvgBar != NAI && g_bar > B.fvgBar && l <= B.fvgBot) { B.fvgTop = NA; B.fvgBot = NA; B.fvgBar = NAI; }
   if(S.fvgBar != NAI && g_bar > S.fvgBar && h >= S.fvgTop) { S.fvgTop = NA; S.fvgBot = NA; S.fvgBar = NAI; }
   if(B.obBar != NAI && g_bar > B.obBar && c < B.obBot) { B.obTop = NA; B.obBot = NA; B.obBar = NAI; }
   if(S.obBar != NAI && g_bar > S.obBar && c > S.obTop) { S.obTop = NA; S.obBot = NA; S.obBar = NAI; }

   //--- zone retests
   bool useFvg = InpEntryZone != Z_OB, useOb = InpEntryZone != Z_FVG;
   bool bFvgRet = B.fvgBar != NAI && g_bar > B.fvgBar && l <= B.fvgTop && h >= B.fvgBot
                  && (InpReqRejection ? c > B.fvgTop : c >= (B.fvgTop + B.fvgBot) / 2) && (!InpReqRetestCandle || c > o);
   bool sFvgRet = S.fvgBar != NAI && g_bar > S.fvgBar && h >= S.fvgBot && l <= S.fvgTop
                  && (InpReqRejection ? c < S.fvgBot : c <= (S.fvgTop + S.fvgBot) / 2) && (!InpReqRetestCandle || c < o);
   bool bObRet = B.obBar != NAI && g_bar > B.obBar && l <= B.obTop && h >= B.obBot
                 && (InpReqRejection ? c > B.obTop : c >= (B.obTop + B.obBot) / 2) && (!InpReqRetestCandle || c > o);
   bool sObRet = S.obBar != NAI && g_bar > S.obBar && h >= S.obBot && l <= S.obTop
                 && (InpReqRejection ? c < S.obBot : c <= (S.obTop + S.obBot) / 2) && (!InpReqRetestCandle || c < o);
   bool bFvgHit = useFvg && bFvgRet, bObHit = useOb && bObRet;
   bool sFvgHit = useFvg && sFvgRet, sObHit = useOb && sObRet;
   bool bZone = InpEntryZone == Z_BOTH ? (bFvgHit && bObHit) : (bFvgHit || bObHit);
   bool sZone = InpEntryZone == Z_BOTH ? (sFvgHit && sObHit) : (sFvgHit || sObHit);
   bool bChochOk = !InpUseChoch || B.chochConf, sChochOk = !InpUseChoch || S.chochConf;
   bool bTiming = B.structBar != NAI && g_bar - B.structBar >= InpMinRetestBars;
   bool sTiming = S.structBar != NAI && g_bar - S.structBar >= InpMinRetestBars;

   //--- premium / discount on the rejection bar
   double bZoneMid = NA, sZoneMid = NA;
   if(bFvgHit && bObHit)
     {
      double ob_ = MathMax(B.fvgBot, B.obBot), ot = MathMin(B.fvgTop, B.obTop);
      bZoneMid = ob_ <= ot ? (ob_ + ot) / 2 : (B.fvgTop >= B.obTop ? (B.fvgTop + B.fvgBot) / 2 : (B.obTop + B.obBot) / 2);
     }
   else if(bFvgHit) bZoneMid = (B.fvgTop + B.fvgBot) / 2;
   else if(bObHit)  bZoneMid = (B.obTop + B.obBot) / 2;
   if(sFvgHit && sObHit)
     {
      double ob_ = MathMax(S.fvgBot, S.obBot), ot = MathMin(S.fvgTop, S.obTop);
      sZoneMid = ob_ <= ot ? (ob_ + ot) / 2 : (S.fvgBot <= S.obBot ? (S.fvgTop + S.fvgBot) / 2 : (S.obTop + S.obBot) / 2);
     }
   else if(sFvgHit) sZoneMid = (S.fvgTop + S.fvgBot) / 2;
   else if(sObHit)  sZoneMid = (S.obTop + S.obBot) / 2;
   double bPd = InpPdRef == PDR_CLOSE ? c : InpPdRef == PDR_WICK ? l : bZoneMid;
   double sPd = InpPdRef == PDR_CLOSE ? c : InpPdRef == PDR_WICK ? h : sZoneMid;
   double lrs = (isna(B.rangeExt) || isna(B.sweepExt)) ? NA : B.rangeExt - B.sweepExt;
   double lRetr = (!isna(lrs) && lrs > g_tick && !isna(bPd)) ? (B.rangeExt - bPd) / lrs : NA;
   bool longPdOk = !InpUsePD || (!isna(lRetr) && (InpPdMode == PD_OTE ? (lRetr >= InpOteStart && lRetr <= InpOteEnd) : lRetr >= 0.5));
   double srs = (isna(S.rangeExt) || isna(S.sweepExt)) ? NA : S.sweepExt - S.rangeExt;
   double sRetr = (!isna(srs) && srs > g_tick && !isna(sPd)) ? (sPd - S.rangeExt) / srs : NA;
   bool shortPdOk = !InpUsePD || (!isna(sRetr) && (InpPdMode == PD_OTE ? (sRetr >= InpOteStart && sRetr <= InpOteEnd) : sRetr >= 0.5));

   bool bRejNow = B.sweepBar != NAI && bZone && bTiming && longPdOk;
   bool sRejNow = S.sweepBar != NAI && sZone && sTiming && shortPdOk;

   //--- confirmation: later close beyond the stored rejection candle, same zone still alive
   bool bAlive = InpEntryZone == Z_BOTH ? (B.rejFvg && B.rejOb && B.fvgBar == B.rejFvgBar && B.obBar == B.rejObBar)
                 : ((B.rejFvg && B.fvgBar == B.rejFvgBar) || (B.rejOb && B.obBar == B.rejObBar));
   bool sAlive = InpEntryZone == Z_BOTH ? (S.rejFvg && S.rejOb && S.fvgBar == S.rejFvgBar && S.obBar == S.rejObBar)
                 : ((S.rejFvg && S.fvgBar == S.rejFvgBar) || (S.rejOb && S.obBar == S.rejObBar));
   bool confStrong = rng > 0 && body >= atr * InpMinConfBodyAtr && body / rng * 100.0 >= InpMinConfBodyPct;
   bool bBreak = InpReqRetestBreak && B.rejBar != NAI && g_bar > B.rejBar && g_bar - B.rejBar <= InpConfirmBars && bAlive
                 && c > B.rejPx && c1 <= B.rejPx && c > o && confStrong && c - B.rejPx <= atr * InpMaxChaseAtr;
   bool sBreak = InpReqRetestBreak && S.rejBar != NAI && g_bar > S.rejBar && g_bar - S.rejBar <= InpConfirmBars && sAlive
                 && c < S.rejPx && c1 >= S.rejPx && c < o && confStrong && S.rejPx - c <= atr * InpMaxChaseAtr;
   bool bZoneOk = InpReqRetestBreak ? bBreak : bRejNow;
   bool sZoneOk = InpReqRetestBreak ? sBreak : sRejNow;
   if(bRejNow) { B.rejBar = g_bar; B.rejPx = h; B.rejFvg = bFvgHit; B.rejOb = bObHit; B.rejFvgBar = bFvgHit ? B.fvgBar : NAI; B.rejObBar = bObHit ? B.obBar : NAI; }
   if(sRejNow) { S.rejBar = g_bar; S.rejPx = l; S.rejFvg = sFvgHit; S.rejOb = sObHit; S.rejFvgBar = sFvgHit ? S.fvgBar : NAI; S.rejObBar = sObHit ? S.obBar : NAI; }
   bool bMtf = !InpReqMtfSweep || B.mtfOk, sMtf = !InpReqMtfSweep || S.mtfOk;

   //--- risk and room
   double bPostBos = (B.bosBar != NAI && g_pl0b != NAI && g_pl0b > B.bosBar && !isna(g_pl0) && g_pl0 < c) ? g_pl0 - atr * InpStopBufAtr : NA;
   double sPostBos = (S.bosBar != NAI && g_ph0b != NAI && g_ph0b > S.bosBar && !isna(g_ph0) && g_ph0 > c) ? g_ph0 + atr * InpStopBufAtr : NA;
   double longStopCand = !isna(B.sweepExt) ? (!isna(bPostBos) ? MathMax(B.stop, bPostBos) : B.stop) : NA;
   double shortStopCand = !isna(S.sweepExt) ? (!isna(sPostBos) ? MathMin(S.stop, sPostBos) : S.stop) : NA;
   double longRisk = isna(longStopCand) ? NA : c - longStopCand;
   double shortRisk = isna(shortStopCand) ? NA : shortStopCand - c;
   bool longStopOk = !isna(longRisk) && longRisk > g_tick && (InpMinStopAtr <= 0 || longRisk >= atr * InpMinStopAtr) && (InpMaxStopAtr <= 0 || longRisk <= atr * InpMaxStopAtr);
   bool shortStopOk = !isna(shortRisk) && shortRisk > g_tick && (InpMinStopAtr <= 0 || shortRisk >= atr * InpMinStopAtr) && (InpMaxStopAtr <= 0 || shortRisk <= atr * InpMaxStopAtr);
   double pdhLvl = InpUsePrevDay ? pdh : NA, pdlLvl = InpUsePrevDay ? pdl : NA;
   double above[5], below[5];
   above[0] = g_swH; above[1] = g_aCH; above[2] = g_lCH; above[3] = g_nCH; above[4] = pdhLvl;
   below[0] = g_swL; below[1] = g_aCL; below[2] = g_lCL; below[3] = g_nCL; below[4] = pdlLvl;
   double nA = NearestAbove(c, above), nB = NearestBelow(c, below);
   bool longRoomOk = !InpRoomFilter || isna(nA) || (!isna(longRisk) && longRisk > 0 && nA - c >= InpMinRoomR * longRisk);
   bool shortRoomOk = !InpRoomFilter || isna(nB) || (!isna(shortRisk) && shortRisk > 0 && c - nB >= InpMinRoomR * shortRisk);
   g_lvlLong[0] = g_ph0;  g_lvlLong[1] = g_swH;  g_lvlLong[2] = g_aCH;  g_lvlLong[3] = g_lCH;  g_lvlLong[4] = g_nCH;  g_lvlLong[5] = pdhLvl;
   g_lvlShort[0] = g_pl0; g_lvlShort[1] = g_swL; g_lvlShort[2] = g_aCL; g_lvlShort[3] = g_lCL; g_lvlShort[4] = g_nCL; g_lvlShort[5] = pdlLvl;

   //--- entries (live bars only)
   int dir = live ? PositionDir() : 0;
   bool longSig = live && trendBull && sessPass && dailyOk && bMtf && B.sweepBar != NAI && B.bosConf && bChochOk && bZoneOk
                  && longStopOk && longRoomOk && LotSize(c, longStopCand) > 0 && (InpAllowReversal ? dir <= 0 : dir == 0);
   bool shortSig = live && trendBear && sessPass && dailyOk && sMtf && S.sweepBar != NAI && S.bosConf && sChochOk && sZoneOk
                   && shortStopOk && shortRoomOk && LotSize(c, shortStopCand) > 0 && (InpAllowReversal ? dir >= 0 : dir == 0) && !longSig;
   if(longSig)
     {
      double lots = LotSize(c, B.stop);   // Pine sizes on the sweep stop, not the candidate
      if(lots > 0) OpenTrade(1, B.stop, lots, c, g_lvlLong);
      g_tradesToday++;
      ResetSetup(B);
     }
   if(shortSig)
     {
      double lots = LotSize(c, S.stop);
      if(lots > 0) OpenTrade(-1, S.stop, lots, c, g_lvlShort);
      g_tradesToday++;
      ResetSetup(S);
     }

   //--- bar-close trade management: structure trail after TP2, time stop before TP1
   if(!live || g_posDir == 0 || g_entryBar == g_bar) return;
   if(PositionDir() != g_posDir) { ResetPos(); return; }
   if(InpTrail && g_tp2Hit)
     {
      if(g_posDir > 0 && !isna(g_pl0)) { double ts = g_pl0 - atr * InpTrailBufAtr; if(ts > g_stop && ts < c) ModifySL(ts); }
      if(g_posDir < 0 && !isna(g_ph0)) { double ts = g_ph0 + atr * InpTrailBufAtr; if(ts < g_stop && ts > c) ModifySL(ts); }
     }
   if(InpMaxBarsInTrade > 0 && g_bar - g_entryBar >= InpMaxBarsInTrade && !g_tp1Hit)
     {
      trade.PositionClose(g_ticket);
      Print("Time stop");
      ResetPos();
     }
  }

//+------------------------------------------------------------------+
bool Warmup()
  {
   if(BarsCalculated(g_emaTrend) <= 0 || BarsCalculated(g_emaSec) <= 0) return false;
   if(iBars(_Symbol, InpLiqTF) < 50 || iBars(_Symbol, PERIOD_D1) < 3) return false;
   int bars = Bars(_Symbol, _Period);
   int start = MathMin(InpWarmupBars, bars - 2 * InpPivotLen - 5);
   if(start < 100) return false;
   for(int s = start; s >= 1; s--) ProcessBar(s, false);
   g_curBarTime = iTime(_Symbol, _Period, 0);
   g_ready = true;
   PrintFormat("Warm-up done: %d bars, ATR %.2f", start, g_atr);
   return true;
  }

int OnInit()
  {
   g_tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_emaTrend = iMA(_Symbol, InpTrendTF, InpTrendEmaLen, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSec = iMA(_Symbol, InpSecTF, InpTrendEmaLen, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaTrend == INVALID_HANDLE || g_emaSec == INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   ResetSetup(B);
   ResetSetup(S);
   ResetPos();
   ArrayInitialize(g_lvlLong, NA);
   ArrayInitialize(g_lvlShort, NA);
   if(PositionDir() != 0) Print("Open position found from before restart: server SL/TP stay, partials/BE/trail are not managed.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(g_emaTrend);
   IndicatorRelease(g_emaSec);
  }

void OnTick()
  {
   if(!g_ready && !Warmup()) return;
   datetime cur = iTime(_Symbol, _Period, 0);
   if(cur != g_curBarTime)
     {
      int last = iBarShift(_Symbol, _Period, g_lastProcTime, true);
      if(last < 1) last = 2;                      // gap in history: process just the last closed bar
      for(int s = last - 1; s >= 1; s--) ProcessBar(s, s == 1);
      g_curBarTime = cur;
     }
   ManageTicks();
  }
//+------------------------------------------------------------------+
