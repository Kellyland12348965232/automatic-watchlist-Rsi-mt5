//+------------------------------------------------------------------+
//|                     RSI_Strategy_Watcher_SMA180_v1.mq5            |
//|            MT5 RSI Strategy Watcher - SMA180 Filter v1            |
//|                30-Day Historical Event Filter                    |
//|                                                                  |
//| Purpose: Multi-symbol RSI market scanner and alert tool.         |
//| This indicator is a SCANNER/ALERT tool ONLY.                     |
//| It must NEVER place, modify, or close trades.                    |
//|                                                                  |
//| Phase 1 (done): foundation - inputs, validation, timer,          |
//| lifecycle handlers, temporary status display.                   |
//| Phase 2 (done): multi-symbol RSI scanning engine over all Market |
//| Watch symbols and enabled timeframes, reusable iRSI handles, and |
//| a temporary Comment() active-signal list.                        |
//| SMA180 v1: preserves Phase 3 history and timeframe pairings, and  |
//| diagnoses trend permission using filter-timeframe Close[1] vs    |
//| SMA(180)[1]. No strategy entries or trading are implemented.     |
//+------------------------------------------------------------------+
#property strict
#property copyright "RSI Market Scanner"
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Project identification
#define PROJECT_NAME    "MT5 RSI Strategy Watcher"
#define PROJECT_VERSION "v1.0 (SMA180 Filter)"

//--- Historical event window configuration
#define SECONDS_PER_DAY              86400
#define HISTORY_LOOKBACK_MARGIN_BARS 50    // closed bars fetched before the cutoff to establish the starting zone
#define SMA_FILTER_PERIOD            180

//--- RSI zone classification
#define ZONE_NONE       0
#define ZONE_OVERSOLD   1
#define ZONE_OVERBOUGHT 2

//--- Qualification requirement
#define MIN_QUALIFYING_EVENTS 3

//--- Input parameters: RSI settings
input int             InpRSIPeriod        = 14;           // RSI Period
input ENUM_APPLIED_PRICE InpRSIAppliedPrice = PRICE_CLOSE; // RSI Applied Price (scanner always uses Close)
input double          InpOverboughtLevel  = 70.0;         // Overbought Threshold
input double          InpOversoldLevel    = 30.0;         // Oversold Threshold

//--- Input parameters: scan timeframes
input bool             InpScanM5  = true;   // Enable Scan Timeframe: M5
input bool             InpScanM15 = true;   // Enable Scan Timeframe: M15
input bool             InpScanH1  = true;   // Enable Scan Timeframe: H1
input bool             InpScanH4  = true;   // Enable Scan Timeframe: H4
input bool             InpScanD1  = true;   // Enable Scan Timeframe: D1

//--- Independent filter timeframe pairing for each entry timeframe
input ENUM_TIMEFRAMES  InpFilterTfM5  = PERIOD_M15; // Filter timeframe for M5 entries
input ENUM_TIMEFRAMES  InpFilterTfM15 = PERIOD_H1;  // Filter timeframe for M15 entries
input ENUM_TIMEFRAMES  InpFilterTfH1  = PERIOD_H4;  // Filter timeframe for H1 entries
input ENUM_TIMEFRAMES  InpFilterTfH4  = PERIOD_D1;  // Filter timeframe for H4 entries
input ENUM_TIMEFRAMES  InpFilterTfD1  = PERIOD_W1;  // Filter timeframe for D1 entries
input bool             InpUseSMA180Filter = true;  // Enable SMA180 directional filter

//--- Input parameters: refresh settings
input int              InpRefreshSeconds = 10;  // Refresh Interval (seconds)

//+------------------------------------------------------------------+
//| One reusable RSI handle + cached 30-day event history for a       |
//| single symbol/timeframe combination. A class (not a struct) is    |
//| used because it must hold dynamic arrays of event timestamps.     |
//+------------------------------------------------------------------+
class CScanHandle
  {
public:
   string            symbol;
   ENUM_TIMEFRAMES   tf;
   string            tfName;
   int               handle;
  ENUM_TIMEFRAMES   filterTf;
  int               smaHandle;
   bool              errorReported;      // avoids flooding the log every refresh

    bool              historyReady;       // true only after a complete initial batch has been committed
    datetime          lastProcessedTime;  // newest CLOSED bar committed to the event lists
   int               zoneState;          // ZONE_* state as of lastProcessedTime

   datetime          oversoldEvents[];   // chronological (ascending) entry timestamps into the oversold zone
   datetime          overboughtEvents[]; // chronological (ascending) entry timestamps into the overbought zone

                     CScanHandle(void)
     {
      symbol            = "";
      tf                = PERIOD_CURRENT;
      tfName            = "";
      handle            = INVALID_HANDLE;
      filterTf          = PERIOD_CURRENT;
      smaHandle         = INVALID_HANDLE;
      errorReported     = false;
      historyReady      = false;
      lastProcessedTime = 0;
      zoneState         = ZONE_NONE;
     }

                    ~CScanHandle(void)
     {
      if(handle != INVALID_HANDLE)
         IndicatorRelease(handle);
      if(smaHandle != INVALID_HANDLE)
        IndicatorRelease(smaHandle);
     }
  };

//--- One qualified, currently-active signal for the temporary display
struct SSignal
  {
   string            symbol;
   string            tfName;
   double            rsi;
   string            status;
   int               oversoldCount;
   int               overboughtCount;
   ENUM_TIMEFRAMES   filterTf;
  };

//--- Internal state
datetime        g_lastRefreshTime = 0;
ulong           g_refreshCount    = 0;
bool            g_timerActive     = false;

ENUM_TIMEFRAMES g_timeframes[];      // enabled scan timeframes (built once from inputs)
string          g_timeframeNames[];  // parallel display names
int             g_timeframeCount   = 0;

string          g_symbols[];         // cached Market Watch symbol list
CScanHandle     *g_handles[];        // one entry per symbol/timeframe combination (pointers - reused across refreshes)
SSignal         g_signals[];         // qualified, currently-active signals found on the last scan

//+------------------------------------------------------------------+
//| Build the list of enabled scan timeframes as a display string     |
//+------------------------------------------------------------------+
string BuildEnabledTimeframesString()
  {
   string list = "";
   if(InpScanM5)
      list += (list == "" ? "" : ", ") + "M5";
   if(InpScanM15)
      list += (list == "" ? "" : ", ") + "M15";
   if(InpScanH1)
      list += (list == "" ? "" : ", ") + "H1";
   if(InpScanH4)
      list += (list == "" ? "" : ", ") + "H4";
   if(InpScanD1)
      list += (list == "" ? "" : ", ") + "D1";
   if(list == "")
      list = "None";
   return list;
  }

//+------------------------------------------------------------------+
//| Build the enabled scan timeframe arrays from the boolean inputs   |
//+------------------------------------------------------------------+
void BuildEnabledTimeframes()
  {
   ArrayResize(g_timeframes, 5);
   ArrayResize(g_timeframeNames, 5);
   g_timeframeCount = 0;

   if(InpScanM5)
     { g_timeframes[g_timeframeCount] = PERIOD_M5;  g_timeframeNames[g_timeframeCount] = "M5";  g_timeframeCount++; }
   if(InpScanM15)
     { g_timeframes[g_timeframeCount] = PERIOD_M15; g_timeframeNames[g_timeframeCount] = "M15"; g_timeframeCount++; }
   if(InpScanH1)
     { g_timeframes[g_timeframeCount] = PERIOD_H1;  g_timeframeNames[g_timeframeCount] = "H1";  g_timeframeCount++; }
   if(InpScanH4)
     { g_timeframes[g_timeframeCount] = PERIOD_H4;  g_timeframeNames[g_timeframeCount] = "H4";  g_timeframeCount++; }
   if(InpScanD1)
     { g_timeframes[g_timeframeCount] = PERIOD_D1;  g_timeframeNames[g_timeframeCount] = "D1";  g_timeframeCount++; }

   ArrayResize(g_timeframes, g_timeframeCount);
   ArrayResize(g_timeframeNames, g_timeframeCount);
  }

//+------------------------------------------------------------------+
//| Return a concise timeframe label for pairing diagnostics.        |
//+------------------------------------------------------------------+
string TimeframeLabel(ENUM_TIMEFRAMES timeframe)
  {
   switch(timeframe)
     {
      case PERIOD_M1:  return("M1");
      case PERIOD_M2:  return("M2");
      case PERIOD_M3:  return("M3");
      case PERIOD_M4:  return("M4");
      case PERIOD_M5:  return("M5");
      case PERIOD_M6:  return("M6");
      case PERIOD_M10: return("M10");
      case PERIOD_M12: return("M12");
      case PERIOD_M15: return("M15");
      case PERIOD_M20: return("M20");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H2:  return("H2");
      case PERIOD_H3:  return("H3");
      case PERIOD_H4:  return("H4");
      case PERIOD_H6:  return("H6");
      case PERIOD_H8:  return("H8");
      case PERIOD_H12: return("H12");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN1");
     }
   return(EnumToString(timeframe));
  }

//+------------------------------------------------------------------+
//| Resolve the configured filter timeframe for an entry timeframe. |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES FilterTimeframeForEntry(ENUM_TIMEFRAMES entryTf)
  {
   switch(entryTf)
     {
      case PERIOD_M5:  return(InpFilterTfM5);
      case PERIOD_M15: return(InpFilterTfM15);
      case PERIOD_H1:  return(InpFilterTfH1);
      case PERIOD_H4:  return(InpFilterTfH4);
      case PERIOD_D1:  return(InpFilterTfD1);
     }
   return(PERIOD_CURRENT);
  }

//+------------------------------------------------------------------+
//| Historical event lookback (days) for each scan timeframe.        |
//+------------------------------------------------------------------+
int HistoryWindowDays(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_H1: return(60);
      case PERIOD_H4: return(180);
      case PERIOD_D1: return(365);
     }
   return(30);
  }

//+------------------------------------------------------------------+
//| Build the configured entry-to-filter pairing diagnostic.         |
//+------------------------------------------------------------------+
string BuildPairingDiagnostic()
  {
   return("Timeframe Pairings: M5 -> " + TimeframeLabel(InpFilterTfM5) +
          " | M15 -> " + TimeframeLabel(InpFilterTfM15) +
          " | H1 -> " + TimeframeLabel(InpFilterTfH1) +
          " | H4 -> " + TimeframeLabel(InpFilterTfH4) +
          " | D1 -> " + TimeframeLabel(InpFilterTfD1));
  }

    //+------------------------------------------------------------------+
    //| Format SMA180 trend permission using the filter timeframe's bar 1.|
    //+------------------------------------------------------------------+
    string BuildSmaDiagnostic(CScanHandle *h)
      {
      string prefix = h.symbol + " " + h.tfName + " -> " + TimeframeLabel(h.filterTf) + " | ";
      if(h.smaHandle == INVALID_HANDLE)
        return(prefix + "SMA180 unavailable | LONG BLOCKED | SHORT BLOCKED");

      long synchronized = 0;
      if(!SeriesInfoInteger(h.symbol, h.filterTf, SERIES_SYNCHRONIZED, synchronized) || synchronized == 0 ||
        BarsCalculated(h.smaHandle) < SMA_FILTER_PERIOD + 1)
        return(prefix + "filter history loading | LONG BLOCKED | SHORT BLOCKED");

      double filterClose[];
      double smaValue[];
      ArraySetAsSeries(filterClose, true);
      ArraySetAsSeries(smaValue, true);

      if(CopyClose(h.symbol, h.filterTf, 1, 1, filterClose) != 1 ||
        CopyBuffer(h.smaHandle, 0, 1, 1, smaValue) != 1 ||
        ArraySize(filterClose) != 1 || ArraySize(smaValue) != 1 ||
        !MathIsValidNumber(filterClose[0]) || !MathIsValidNumber(smaValue[0]))
        return(prefix + "closed data unavailable | LONG BLOCKED | SHORT BLOCKED");

      int digits = (int)SymbolInfoInteger(h.symbol, SYMBOL_DIGITS);
      string details = prefix + TimeframeLabel(h.filterTf) + " Close " +
                  DoubleToString(filterClose[0], digits) + " | SMA180 " +
                  DoubleToString(smaValue[0], digits) + " | ";

      if(filterClose[0] > smaValue[0])
        return(details + "BULLISH | LONG ALLOWED | SHORT BLOCKED");
      if(filterClose[0] < smaValue[0])
        return(details + "BEARISH | LONG BLOCKED | SHORT ALLOWED");
      return(details + "NEUTRAL | LONG BLOCKED | SHORT BLOCKED");
      }

//+------------------------------------------------------------------+
//| Refresh the cached Market Watch symbol list.                      |
//| Returns true if the symbol list changed since the last call.      |
//+------------------------------------------------------------------+
bool RefreshSymbolList()
  {
   int total = SymbolsTotal(true);
   string newSymbols[];
   ArrayResize(newSymbols, total);
   for(int i = 0; i < total; i++)
      newSymbols[i] = SymbolName(i, true);
   ArraySort(newSymbols);

   bool changed = (ArraySize(newSymbols) != ArraySize(g_symbols));
   if(!changed)
     {
      for(int i = 0; i < total; i++)
        {
         if(newSymbols[i] != g_symbols[i])
           {
            changed = true;
            break;
           }
        }
     }

   if(changed)
     {
      ArrayResize(g_symbols, total);
      for(int i = 0; i < total; i++)
         g_symbols[i] = newSymbols[i];
     }
   return(changed);
  }

//+------------------------------------------------------------------+
//| Classify an RSI reading into a zone using the configured levels   |
//+------------------------------------------------------------------+
int ClassifyZone(double rsi)
  {
   if(rsi >= InpOverboughtLevel)
      return(ZONE_OVERBOUGHT);
   if(rsi <= InpOversoldLevel)
      return(ZONE_OVERSOLD);
   return(ZONE_NONE);
  }

//+------------------------------------------------------------------+
//| Append a unique, chronological zone-entry timestamp.              |
//+------------------------------------------------------------------+
bool AppendEvent(datetime &events[], datetime eventTime)
  {
   int n = ArraySize(events);
  if(n > 0 && events[n - 1] >= eventTime)
    return(false);
  if(ArrayResize(events, n + 1) != n + 1)
    return(false);
   events[n] = eventTime;
  return(true);
  }

//+------------------------------------------------------------------+
//| Drop event timestamps older than the cutoff (memory hygiene only; |
//| correctness of the 30-day filter comes from CountEventsInWindow). |
//+------------------------------------------------------------------+
bool PruneEvents(datetime &events[], datetime cutoff)
  {
   int n = ArraySize(events);
   int dropCount = 0;
   while(dropCount < n && events[dropCount] < cutoff)
      dropCount++;

   if(dropCount > 0)
     {
      int remaining = n - dropCount;
      for(int i = 0; i < remaining; i++)
         events[i] = events[dropCount + i];
      if(ArrayResize(events, remaining) != remaining)
        return(false);
     }
    return(true);
  }

//+------------------------------------------------------------------+
//| Count events whose entry timestamp falls within [cutoff, now].    |
//| Array is chronological ascending, so we can scan from the newest  |
//| end and stop at the first entry older than the cutoff.            |
//+------------------------------------------------------------------+
int CountEventsInWindow(const datetime &events[], datetime cutoff)
  {
  int low = 0;
  int high = ArraySize(events);
  while(low < high)
     {
    int middle = low + (high - low) / 2;
    if(events[middle] < cutoff)
      low = middle + 1;
      else
      high = middle;
     }
  return(ArraySize(events) - low);
  }

//+------------------------------------------------------------------+
//| Report a history issue once until a successful recovery.         |
//+------------------------------------------------------------------+
void ReportHistoryIssue(CScanHandle *h, string message)
  {
   if(!h.errorReported)
     {
      Print("RSI_Market_Scanner_Phase3_New: ", h.symbol, " ", h.tfName, ": ", message);
      h.errorReported = true;
     }
  }

//+------------------------------------------------------------------+
//| Copy both cached event lists to temporary arrays before mutation. |
//+------------------------------------------------------------------+
bool StageEventLists(CScanHandle *h, datetime &oversold[], datetime &overbought[])
  {
  if(ArrayCopy(oversold, h.oversoldEvents) != ArraySize(h.oversoldEvents))
    return(false);
  if(ArrayCopy(overbought, h.overboughtEvents) != ArraySize(h.overboughtEvents))
    return(false);
  return(true);
  }

//+------------------------------------------------------------------+
//| Swap staged event arrays into the cache, rolling back on failure. |
//+------------------------------------------------------------------+
bool CommitEventLists(CScanHandle *h, datetime &oversold[], datetime &overbought[])
  {
   if(!ArraySwap(h.oversoldEvents, oversold))
      return(false);
   if(!ArraySwap(h.overboughtEvents, overbought))
     {
      ArraySwap(h.oversoldEvents, oversold);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Prune expired events on refreshes without a new closed candle.    |
//+------------------------------------------------------------------+
bool PruneCachedEvents(CScanHandle *h, datetime cutoff)
  {
  datetime stagedOversold[];
  datetime stagedOverbought[];
  if(!StageEventLists(h, stagedOversold, stagedOverbought))
    return(false);
  if(!PruneEvents(stagedOversold, cutoff) || !PruneEvents(stagedOverbought, cutoff))
    return(false);
  return(CommitEventLists(h, stagedOversold, stagedOverbought));
  }

//+------------------------------------------------------------------+
//| Confirm a short initial batch is the broker's complete history. |
//+------------------------------------------------------------------+
bool IsAvailableHistoryComplete(CScanHandle *h,
                                datetime requestedFrom,
                                int requestedShift,
                                const datetime &times[])
  {
   if(requestedShift > 0)
     {
      datetime anchorTime = iTime(h.symbol, h.tf, requestedShift);
      return(anchorTime != 0 && anchorTime <= requestedFrom && times[0] == anchorTime);
     }

   if(ArraySize(times) == 0)
      return(false);

   long firstSeriesDate = 0;
   long firstServerDate = 0;
   if(!SeriesInfoInteger(h.symbol, h.tf, SERIES_FIRSTDATE, firstSeriesDate) ||
      !SeriesInfoInteger(h.symbol, h.tf, SERIES_SERVER_FIRSTDATE, firstServerDate))
      return(false);

   // The synchronized timeframe must start at the first returned bar, and the server must have no older data.
   return(firstSeriesDate == (long)times[0] &&
          (datetime)firstSeriesDate > requestedFrom &&
          firstServerDate != 0 && firstServerDate >= (long)requestedFrom);
  }

//+------------------------------------------------------------------+
//| Build or incrementally update the closed-bar history cache.       |
//| Every copy is validated and processed in temporary arrays before  |
//| any cached history or progress state is changed.                  |
//+------------------------------------------------------------------+
bool EnsureHistory(CScanHandle *h, datetime cutoff)
  {
   if(h == NULL || h.handle == INVALID_HANDLE)
      return(false);

   long synchronized = 0;
   if(!SeriesInfoInteger(h.symbol, h.tf, SERIES_SYNCHRONIZED, synchronized) || synchronized == 0)
     {
      ReportHistoryIssue(h, "price history is not synchronized; retrying");
      return(h.historyReady);
     }

   int calculated = BarsCalculated(h.handle);
   if(calculated < 0)
     {
      ReportHistoryIssue(h, "BarsCalculated failed, error " + IntegerToString(GetLastError()));
      return(h.historyReady);
     }
   if(calculated == 0)
     {
      ReportHistoryIssue(h, "RSI history is not calculated yet; retrying");
      return(h.historyReady);
     }

//--- newest fully CLOSED bar (shift 1); the forming bar (shift 0) is never part of history counting
   datetime newestClosed = iTime(h.symbol, h.tf, 1);
   if(newestClosed == 0)
     {
      ReportHistoryIssue(h, "no closed bar is available yet; retrying");
      return(h.historyReady);
     }

   bool isFullBuild = !h.historyReady;

   if(!isFullBuild && newestClosed <= h.lastProcessedTime)
     {
      if(!PruneCachedEvents(h, cutoff))
         ReportHistoryIssue(h, "could not prune expired events; cached history retained");
      else
         h.errorReported = false;
      return(true);
     }

   int periodSecs = PeriodSeconds(h.tf);
   if(periodSecs <= 0)
      periodSecs = 60;

   datetime requestedFrom = cutoff - (datetime)(periodSecs * HISTORY_LOOKBACK_MARGIN_BARS);
   int expectedBars = 0;
   int requestedShift = -1;
   int lastProcessedShift = -1;
   int startZone = isFullBuild ? ZONE_NONE : h.zoneState;

   if(isFullBuild)
     {
      requestedShift = iBarShift(h.symbol, h.tf, requestedFrom, false);
      if(requestedShift == 0)
        {
         ReportHistoryIssue(h, "initial history start resolved to the forming candle");
         return(false);
        }

      if(requestedShift > 0)
         expectedBars = requestedShift;
      else
        {
         long seriesBars = 0;
         if(!SeriesInfoInteger(h.symbol, h.tf, SERIES_BARS_COUNT, seriesBars) || seriesBars <= 1)
           {
            ReportHistoryIssue(h, "not enough synchronized bars to build initial history");
            return(false);
           }
         expectedBars = (int)seriesBars - 1;
        }
     }
   else
     {
      lastProcessedShift = iBarShift(h.symbol, h.tf, h.lastProcessedTime, true);
      if(lastProcessedShift < 2)
        {
         ReportHistoryIssue(h, "last committed closed candle is unavailable; retrying");
         return(h.historyReady);
        }
      expectedBars = lastProcessedShift - 1;
     }

   if(expectedBars <= 0 || calculated < expectedBars)
     {
      ReportHistoryIssue(h, "RSI has not calculated the complete requested history; retrying");
      return(h.historyReady);
     }

   datetime times[];
   double   rsiVals[];

   int copiedTimes = CopyTime(h.symbol, h.tf, 1, expectedBars, times);
   if(copiedTimes < 0)
     {
      ReportHistoryIssue(h, "CopyTime failed, error " + IntegerToString(GetLastError()));
      return(h.historyReady);
     }

   int copiedRsi = CopyBuffer(h.handle, 0, 1, expectedBars, rsiVals);
   if(copiedRsi < 0)
     {
      ReportHistoryIssue(h, "CopyBuffer failed, error " + IntegerToString(GetLastError()));
      return(h.historyReady);
     }

//--- force strictly chronological order (oldest at index 0) regardless of default series direction
   ArraySetAsSeries(times, false);
   ArraySetAsSeries(rsiVals, false);

   int n = ArraySize(times);
   if(copiedTimes == 0 || copiedRsi == 0)
     {
      ReportHistoryIssue(h, "CopyTime or CopyBuffer returned zero bars; retrying");
      return(h.historyReady);
     }
   if(copiedTimes != copiedRsi || copiedTimes != expectedBars || n != copiedTimes ||
      ArraySize(rsiVals) != copiedRsi)
     {
      ReportHistoryIssue(h, "timestamp and RSI arrays are incomplete or misaligned; retrying");
      return(h.historyReady);
     }

   for(int i = 0; i < n; i++)
     {
      if(times[i] <= 0 || times[i] > newestClosed ||
         (i > 0 && times[i] <= times[i - 1]))
        {
         ReportHistoryIssue(h, "bar timestamps are invalid or not chronological; retrying");
         return(h.historyReady);
        }
     }

   if(times[n - 1] != newestClosed)
     {
      ReportHistoryIssue(h, "copied history does not end at the newest closed candle; retrying");
      return(h.historyReady);
     }

   if(isFullBuild)
     {
      if(!IsAvailableHistoryComplete(h, requestedFrom, requestedShift, times))
        {
         ReportHistoryIssue(h, "initial history start is incomplete and broker history does not prove an earlier boundary");
         return(false);
        }
     }
   else if(times[0] <= h.lastProcessedTime ||
           iTime(h.symbol, h.tf, lastProcessedShift) != h.lastProcessedTime)
     {
      ReportHistoryIssue(h, "incremental batch overlaps or cannot be aligned to the last committed candle");
      return(h.historyReady);
     }

   int firstValidRsi = 0;
   if(isFullBuild)
     {
      while(firstValidRsi < n &&
            (!MathIsValidNumber(rsiVals[firstValidRsi]) ||
             rsiVals[firstValidRsi] < 0.0 || rsiVals[firstValidRsi] > 100.0))
         firstValidRsi++;
      if(firstValidRsi >= n)
        {
         ReportHistoryIssue(h, "initial RSI history contains no calculated values; retrying");
         return(false);
        }
      if(requestedShift > 0 && times[firstValidRsi] >= cutoff)
        {
         ReportHistoryIssue(h, "not enough valid pre-window RSI values to establish the starting zone");
         return(false);
        }
     }

   for(int i = firstValidRsi; i < n; i++)
     {
      if(!MathIsValidNumber(rsiVals[i]) || rsiVals[i] < 0.0 || rsiVals[i] > 100.0)
        {
         ReportHistoryIssue(h, "batch contains an invalid RSI value; retrying");
         return(h.historyReady);
        }
     }

   datetime stagedOversold[];
   datetime stagedOverbought[];
   if(!StageEventLists(h, stagedOversold, stagedOverbought))
     {
      ReportHistoryIssue(h, "could not stage event lists; retrying");
      return(h.historyReady);
     }

   int zoneState = startZone;
   for(int i = firstValidRsi; i < n; i++)
     {
      int zone = ClassifyZone(rsiVals[i]);
      bool hasPreviousZone = !isFullBuild || i > firstValidRsi;
      if(hasPreviousZone && zone != ZONE_NONE && zone != zoneState && times[i] >= cutoff)
        {
         if(zone == ZONE_OVERSOLD)
           {
            if(!AppendEvent(stagedOversold, times[i]))
              {
               ReportHistoryIssue(h, "could not stage a unique oversold event; retrying");
               return(h.historyReady);
              }
           }
         else
           {
            if(!AppendEvent(stagedOverbought, times[i]))
              {
               ReportHistoryIssue(h, "could not stage a unique overbought event; retrying");
               return(h.historyReady);
              }
           }
        }
      zoneState = zone;
     }

   if(!PruneEvents(stagedOversold, cutoff) || !PruneEvents(stagedOverbought, cutoff))
     {
      ReportHistoryIssue(h, "could not prune staged event lists; cached history retained");
      return(h.historyReady);
     }
   if(!CommitEventLists(h, stagedOversold, stagedOverbought))
     {
      ReportHistoryIssue(h, "could not atomically commit event lists; cached history retained");
      return(h.historyReady);
     }

   h.zoneState         = zoneState;
   h.lastProcessedTime = times[n - 1];
   h.historyReady      = true;
   h.errorReported     = false;

   return(true);
  }

//+------------------------------------------------------------------+
//| Reconcile RSI handles with the current symbol/timeframe grid.    |
//| Existing handles (and their cached event history) are reused;    |
//| only missing combinations create a new handle; handles for       |
//| removed symbols are deleted, which releases the RSI handle too.  |
//+------------------------------------------------------------------+
void RebuildHandles()
  {
   int oldCount = ArraySize(g_handles);
   bool used[];
   ArrayResize(used, oldCount);
   for(int i = 0; i < oldCount; i++)
      used[i] = false;

   int newCount = ArraySize(g_symbols) * g_timeframeCount;
   CScanHandle *newHandles[];
   ArrayResize(newHandles, newCount);

   int idx = 0;
   for(int s = 0; s < ArraySize(g_symbols); s++)
     {
      for(int t = 0; t < g_timeframeCount; t++)
        {
         string          sym = g_symbols[s];
         ENUM_TIMEFRAMES tf  = g_timeframes[t];

         int foundIndex = -1;
         for(int k = 0; k < oldCount; k++)
           {
            if(!used[k] && g_handles[k].symbol == sym && g_handles[k].tf == tf)
              {
               foundIndex = k;
               break;
              }
           }

         CScanHandle *entry;
         if(foundIndex >= 0)
           {
            entry = g_handles[foundIndex];
            used[foundIndex] = true;
           }
         else
           {
            entry = new CScanHandle();
            entry.symbol = sym;
            entry.tf     = tf;
            entry.tfName = g_timeframeNames[t];
            entry.handle = iRSI(sym, tf, InpRSIPeriod, PRICE_CLOSE);
            entry.filterTf = FilterTimeframeForEntry(tf);
            entry.smaHandle = iMA(sym, entry.filterTf, SMA_FILTER_PERIOD, 0, MODE_SMA, PRICE_CLOSE);
            if(entry.handle == INVALID_HANDLE)
               Print("RSI_Market_Scanner_Phase3_New: failed to create RSI handle for ", sym, " ", entry.tfName,
                     ", error ", GetLastError());
            if(entry.smaHandle == INVALID_HANDLE)
               Print("RSI_Strategy_Watcher_SMA180_v1: failed to create SMA180 handle for ", sym, " ",
                 TimeframeLabel(entry.filterTf), ", error ", GetLastError());
           }

         newHandles[idx] = entry;
         idx++;
        }
     }

//--- delete handles that are no longer needed (symbol removed from Market Watch); destructor releases the RSI handle
   for(int k = 0; k < oldCount; k++)
     {
      if(!used[k])
         delete g_handles[k];
     }

   ArrayFree(g_handles);
   ArrayResize(g_handles, newCount);
   for(int i = 0; i < newCount; i++)
      g_handles[i] = newHandles[i];
  }

//+------------------------------------------------------------------+
//| Release every RSI handle currently held (used on shutdown)        |
//+------------------------------------------------------------------+
void ReleaseAllHandles()
  {
   for(int i = 0; i < ArraySize(g_handles); i++)
      delete g_handles[i]; // destructor releases the underlying RSI handle
   ArrayFree(g_handles);
  }

//+------------------------------------------------------------------+
//| Update the 30-day event cache for every handle, then build the    |
//| list of combinations that qualify (>=3 oversold AND >=3            |
//| overbought events in the last 30 days) AND currently show an       |
//| active OVERBOUGHT/OVERSOLD reading on the forming candle.          |
//+------------------------------------------------------------------+
void ScanHandles()
  {
   ArrayFree(g_signals);
   int handleCount = ArraySize(g_handles);
   ArrayResize(g_signals, handleCount);
   int sigCount = 0;

   datetime now = TimeCurrent();

   for(int i = 0; i < handleCount; i++)
     {
      CScanHandle *h = g_handles[i];
      if(h == NULL || h.handle == INVALID_HANDLE)
         continue;

      datetime cutoff = now - (datetime)(HistoryWindowDays(h.tf) * SECONDS_PER_DAY);

//--- keep the cached event history current (cheap after the first full build per handle)
      EnsureHistory(h, cutoff);

//--- current RSI must always use shift 0 (the forming candle), independent of the cached history
      double curBuf[];
      ArraySetAsSeries(curBuf, true);
      if(CopyBuffer(h.handle, 0, 0, 1, curBuf) <= 0)
         continue;

      double currentRsi = curBuf[0];
      string status     = "";
      if(currentRsi >= InpOverboughtLevel)
         status = "OVERBOUGHT";
      else if(currentRsi <= InpOversoldLevel)
         status = "OVERSOLD";
      else
         continue; // between thresholds - never an active signal, regardless of history

      if(!h.historyReady)
         continue; // do not qualify on incomplete event counts

      int oversoldCount   = CountEventsInWindow(h.oversoldEvents, cutoff);
      int overboughtCount = CountEventsInWindow(h.overboughtEvents, cutoff);
      if(status == "OVERSOLD" && oversoldCount < MIN_QUALIFYING_EVENTS)
         continue;
      if(status == "OVERBOUGHT" && overboughtCount < MIN_QUALIFYING_EVENTS)
         continue;

      if(InpUseSMA180Filter)
        {
         if(h.smaHandle == INVALID_HANDLE)
            continue;

         long filterSynchronized = 0;
         if(!SeriesInfoInteger(h.symbol, h.filterTf, SERIES_SYNCHRONIZED, filterSynchronized) ||
            filterSynchronized == 0 || BarsCalculated(h.smaHandle) < SMA_FILTER_PERIOD + 1)
            continue;

         double filterClose[];
         double smaValue[];
         ArraySetAsSeries(filterClose, true);
         ArraySetAsSeries(smaValue, true);
         if(CopyClose(h.symbol, h.filterTf, 1, 1, filterClose) != 1 ||
            CopyBuffer(h.smaHandle, 0, 1, 1, smaValue) != 1 ||
            ArraySize(filterClose) != 1 || ArraySize(smaValue) != 1 ||
            !MathIsValidNumber(filterClose[0]) || !MathIsValidNumber(smaValue[0]))
          continue;

         if(status == "OVERSOLD")
           {
            if(filterClose[0] <= smaValue[0])
               continue;
            status = "LONG";
           }
         else
           {
            if(filterClose[0] >= smaValue[0])
               continue;
            status = "SHORT";
           }
        }
      else if(status == "OVERSOLD")
        status = "LONG";
      else
        status = "SHORT";

      g_signals[sigCount].symbol          = h.symbol;
      g_signals[sigCount].tfName          = h.tfName;
      g_signals[sigCount].rsi             = currentRsi;
      g_signals[sigCount].status          = status;
      g_signals[sigCount].oversoldCount   = oversoldCount;
      g_signals[sigCount].overboughtCount = overboughtCount;
      g_signals[sigCount].filterTf        = h.filterTf;
      sigCount++;
     }

   ArrayResize(g_signals, sigCount);
  }

#define CANDIDATE_CSV_FILE "RSI_Watcher_Candidates.csv"

string g_loggedCandidates[];       // symbol|tf|direction keys already logged and still qualified
bool   g_csvErrorReported = false;
int    g_candidatesLogged = 0;
bool   g_csvWriteSucceeded = false;

//+------------------------------------------------------------------+
//| Append one candidate row to the Common Files CSV. Never throws;   |
//| returns false on any open/write failure.                          |
//+------------------------------------------------------------------+
bool AppendCandidateCsv(const SSignal &s)
  {
   ResetLastError();
   int fh = FileOpen(CANDIDATE_CSV_FILE, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ, ',');
   if(fh == INVALID_HANDLE)
     {
      if(!g_csvErrorReported)
        {
         Print("RSI_Strategy_Watcher: cannot open ", CANDIDATE_CSV_FILE, ", error ", GetLastError());
         g_csvErrorReported = true;
        }
      return(false);
     }

   bool ok = true;
   if(FileSize(fh) == 0)
      ok = (FileWrite(fh, "DetectedAt", "Symbol", "SignalTimeframe", "Direction", "CurrentRSI",
                      "OversoldEvents", "OverboughtEvents", "SMA180FilterEnabled", "SMA180FilterTimeframe") > 0);
   if(ok)
      ok = FileSeek(fh, 0, SEEK_END);
   if(ok)
      ok = (FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), s.symbol, s.tfName, s.status,
                      DoubleToString(s.rsi, 2), s.oversoldCount, s.overboughtCount,
                      (InpUseSMA180Filter ? "TRUE" : "FALSE"), TimeframeLabel(s.filterTf)) > 0);
   FileClose(fh);

   if(!ok)
     {
      if(!g_csvErrorReported)
        {
         Print("RSI_Strategy_Watcher: write to ", CANDIDATE_CSV_FILE, " failed");
         g_csvErrorReported = true;
        }
      return(false);
     }

   g_csvErrorReported = false;
   g_candidatesLogged++;
   g_csvWriteSucceeded = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| Log candidates that were not qualified on the previous scan.      |
//| A failed write is left unlogged so it is retried next cycle.      |
//+------------------------------------------------------------------+
void LogNewCandidates()
  {
   string current[];
   for(int i = 0; i < ArraySize(g_signals); i++)
     {
      string key = g_signals[i].symbol + "|" + g_signals[i].tfName + "|" + g_signals[i].status;
      bool alreadyLogged = false;
      for(int k = 0; k < ArraySize(g_loggedCandidates); k++)
        {
         if(g_loggedCandidates[k] == key)
           {
            alreadyLogged = true;
            break;
           }
        }

      if(!alreadyLogged && !AppendCandidateCsv(g_signals[i]))
         continue;

      int n = ArraySize(current);
      ArrayResize(current, n + 1);
      current[n] = key;
     }

   ArrayResize(g_loggedCandidates, 0);
   ArrayCopy(g_loggedCandidates, current);
  }

//+------------------------------------------------------------------+
//| Refresh the symbol list, reconcile handles if needed, and scan    |
//+------------------------------------------------------------------+
void PerformScanCycle()
  {
   bool symbolsChanged = RefreshSymbolList();
   if(symbolsChanged)
      RebuildHandles();

   ScanHandles();
   LogNewCandidates();
   Comment(BuildScanComment());
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Build the temporary Phase 3 scan status text                      |
//+------------------------------------------------------------------+
string BuildScanComment()
  {
   string status = "";
   status += PROJECT_NAME + " - " + PROJECT_VERSION + "\r\n";
   status += "Status: RUNNING\r\n";
   status += "RSI Period: " + IntegerToString(InpRSIPeriod) + " | Applied Price: Close\r\n";
   status += "Overbought / Oversold: " + DoubleToString(InpOverboughtLevel, 1) + " / " + DoubleToString(InpOversoldLevel, 1) + "\r\n";
   status += BuildPairingDiagnostic() + "\r\n";
   status += "SMA180 Filter: " + (InpUseSMA180Filter ? "ON" : "OFF") + "\r\n";
   status += "Qualification: >= " + IntegerToString(MIN_QUALIFYING_EVENTS) +
             " events per direction | M5/M15 30d, H1 60d, H4 180d, D1 365d\r\n";
   status += "Symbols Scanned: " + IntegerToString(ArraySize(g_symbols)) +
             " | Enabled Combinations: " + IntegerToString(ArraySize(g_handles)) + "\r\n";
   status += "CSV Logger: " + (g_csvErrorReported ? "ERROR" : (g_csvWriteSucceeded ? "ACTIVE" : "WAITING")) + "\r\n";
   status += "Candidates logged this session: " + IntegerToString(g_candidatesLogged) + "\r\n";
   status += "CSV File: " + CANDIDATE_CSV_FILE + " (Common Files)\r\n";
    status += "\r\nQUALIFIED SETUPS\r\n";
    status += "--------------------\r\n";

   if(ArraySize(g_signals) == 0)
    status += "None\r\n";
   else
     {
      for(int i = 0; i < ArraySize(g_signals); i++)
        {
      status += g_signals[i].symbol + " " + g_signals[i].tfName + "   RSI=" +
             DoubleToString(g_signals[i].rsi, 1) + "   " + g_signals[i].status + "\r\n";
        }
     }

   return(status);
  }

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Validate RSI period
   if(InpRSIPeriod < 1)
     {
      Print("RSI_Market_Scanner_Phase3_New: invalid RSI period (", InpRSIPeriod, "). Must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- Validate thresholds are within 0-100
   if(InpOverboughtLevel < 0.0 || InpOverboughtLevel > 100.0 ||
      InpOversoldLevel   < 0.0 || InpOversoldLevel   > 100.0)
     {
      Print("RSI_Market_Scanner_Phase3_New: invalid thresholds. Overbought=", InpOverboughtLevel,
            " Oversold=", InpOversoldLevel, ". Both must be within 0-100.");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- Validate oversold < overbought
   if(InpOversoldLevel >= InpOverboughtLevel)
     {
      Print("RSI_Market_Scanner_Phase3_New: invalid thresholds. Oversold (", InpOversoldLevel,
            ") must be lower than Overbought (", InpOverboughtLevel, ").");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- Validate refresh interval
   if(InpRefreshSeconds < 1)
     {
      Print("RSI_Market_Scanner_Phase3_New: invalid refresh interval (", InpRefreshSeconds, "). Must be >= 1 second.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRSIAppliedPrice != PRICE_CLOSE)
      Print("RSI_Market_Scanner_Phase3_New: InpRSIAppliedPrice is informational only - the scanner always uses PRICE_CLOSE.");

//--- Start the refresh timer
   if(!EventSetTimer(InpRefreshSeconds))
     {
      Print("RSI_Market_Scanner_Phase3_New: EventSetTimer failed, error code ", GetLastError());
      return(INIT_FAILED);
     }
   g_timerActive = true;

   g_refreshCount    = 0;
   g_candidatesLogged = 0;
   g_csvWriteSucceeded = false;
   g_lastRefreshTime = TimeCurrent();

   BuildEnabledTimeframes();
   PerformScanCycle();

  Print("RSI_Market_Scanner_Phase3_New: initialized successfully (", PROJECT_VERSION, ").");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_timerActive)
     {
      EventKillTimer();
      g_timerActive = false;
     }

   ReleaseAllHandles();
   Comment("");

  Print("RSI_Market_Scanner_Phase3_New: shutting down, deinit reason = ", reason);
  }

//+------------------------------------------------------------------+
//| Timer event handler - updates refresh state and rescans           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_lastRefreshTime = TimeCurrent();
   g_refreshCount++;

//--- Phase 3: refresh the symbol list (if needed), update 30-day history caches, and rescan
   PerformScanCycle();
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                                |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
//--- No chart-series calculations implemented - all scanning runs on the timer
   return(rates_total);
  }
//+------------------------------------------------------------------+
