//+------------------------------------------------------------------+
//|                                        GoldDailyBreakout_EA.mq5 |
//|                                    Gold Daily Breakout Strategy |
//|                          Buy/Sell Stop at Previous Day Extremes |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Risk Management ==="
input double   InpRiskPercent      = 0.5;        // Risk % per trade
input double   InpFixedSLPips      = 30;         // Fixed SL in pips (0=use daily range)
input double   InpRiskFreeRR       = 1.0;        // Move to risk-free at this RR
input double   InpInitialTPRatio   = 6.0;        // Initial TP Risk:Reward (1:6)
input double   InpMaxLossAmount    = 10000;      // Max loss per trade $ (caps lot size)
input bool     InpReduceFridayLots = true;       // Reduce Friday lots by 50%

input group "=== Trading Settings ==="
input int      InpMagicNumber      = 123456;     // Magic Number
input double   InpMaxSpread        = 50;         // Max Spread (points)
input int      InpSlippage         = 30;         // Max Slippage (points)
input double   InpOrderOffset      = 10;         // Order offset from wick (points)

input group "=== Session Filter ==="
input bool     InpUseSessionFilter = false;      // Enable session filter
input int      InpSessionStartHour = 0;          // Session start hour
input int      InpSessionEndHour   = 23;         // Session end hour
input bool     InpCloseBeforeWeekend = true;     // Close positions before weekend
input int      InpFridayCloseHour  = 18;         // Hour to close on Friday (server time)
input int      InpFridayNoNewTrades = 18;        // No new trades on Friday after this hour

input group "=== Daily Limits ==="
input int      InpMaxDailyTrades   = 1;          // Max trades per day (0=unlimited)
input double   InpMaxDailyLoss     = 0;          // Max daily loss % (0=disabled)

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
COrderInfo     m_order;

datetime       g_lastBarTime = 0;
datetime       g_lastH1BarTime = 0;
int            g_dailyTradeCount = 0;
datetime       g_lastTradeDay = 0;
double         g_dailyStartBalance = 0;

// Position tracking
struct PositionData
{
   ulong  ticket;
   double entryPrice;
   double originalSL;
   double originalLots;
   double riskDistance;    // Store original risk distance for TP calculation
   bool   riskFreeSet;     // SL moved to breakeven at 1:1
   bool   partialClosed;   // 50% closed at 1:2
   int    positionType;    // 0=buy, 1=sell
};

PositionData g_positions[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   if(StringFind(Symbol(), "GOLD") < 0 && StringFind(Symbol(), "XAU") < 0)
   {
      Print("Warning: This EA is designed for Gold. Current symbol: ", Symbol());
   }
   
   //--- Setup trade object
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   m_trade.SetTypeFillingBySymbol(Symbol());
   
   //--- Initialize daily tracking
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastTradeDay = TimeCurrent();
   
   Print("GoldDailyBreakout EA initialized on ", Symbol());
   Print("Risk: ", InpRiskPercent, "% | Magic: ", InpMagicNumber);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Delete pending orders on removal
   DeletePendingOrders();
   Print("GoldDailyBreakout EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Trade Transaction Event Handler                                   |
//| Deletes opposite pending order when one triggers                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   //--- Check if a pending order was executed (triggered)
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE && trans.order_state == ORDER_STATE_FILLED)
   {
      //--- An order was filled, check if it's our order
      if(trans.symbol == Symbol())
      {
         //--- Delete any remaining pending orders for this symbol with our magic
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(m_order.SelectByIndex(i))
            {
               if(m_order.Symbol() == Symbol() && m_order.Magic() == InpMagicNumber)
               {
                  ulong orderTicket = m_order.Ticket();
                  if(m_trade.OrderDelete(orderTicket))
                  {
                     Print("Opposite pending order deleted: ", orderTicket);
                  }
               }
            }
         }
      }
   }
   
   //--- Also handle DEAL_ADD for safety (when new deal is added)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.symbol == Symbol())
      {
         //--- Small delay then delete pending orders
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(m_order.SelectByIndex(i))
            {
               if(m_order.Symbol() == Symbol() && m_order.Magic() == InpMagicNumber)
               {
                  ulong orderTicket = m_order.Ticket();
                  if(m_trade.OrderDelete(orderTicket))
                  {
                     Print("Opposite pending order deleted on deal: ", orderTicket);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Close positions before weekend
   if(InpCloseBeforeWeekend && IsWeekendCloseTime())
   {
      static datetime lastWeekendCloseLog = 0;
      if(TimeCurrent() - lastWeekendCloseLog > 3600) // Log once per hour max
      {
         Print("=== WEEKEND CLOSE: Closing all positions and cancelling orders ===");
         lastWeekendCloseLog = TimeCurrent();
      }
      CloseAllPositions();
      DeletePendingOrders();
      return;
   }
   
   //--- Check for new daily bar - place pending orders
   if(IsNewDailyBar())
   {
      ResetDailyCounters();
      ProcessDailySignals();
   }
   
   //--- Manage open positions
   ManageOpenPositions();
   
   //--- Check for new M15 bar - trailing stop logic
   if(IsNewM15Bar())
   {
      UpdateTrailingStops();
   }
}

//+------------------------------------------------------------------+
//| Check for new daily bar                                           |
//+------------------------------------------------------------------+
bool IsNewDailyBar()
{
   datetime currentBarTime = iTime(Symbol(), PERIOD_D1, 0);
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check for new M15 bar (for trailing stop)                         |
//+------------------------------------------------------------------+
bool IsNewM15Bar()
{
   datetime currentM15Time = iTime(Symbol(), PERIOD_M15, 0);
   if(currentM15Time != g_lastH1BarTime)
   {
      g_lastH1BarTime = currentM15Time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if it's time to close before weekend                        |
//+------------------------------------------------------------------+
bool IsWeekendCloseTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Friday = day 5, close at specified hour
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
   {
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all open positions                                          |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;
         
      if(m_position.Symbol() != Symbol())
         continue;
         
      if(m_position.Magic() != InpMagicNumber)
         continue;
      
      ulong ticket = m_position.Ticket();
      if(m_trade.PositionClose(ticket))
      {
         Print("Weekend close: Position ", ticket, " closed");
      }
   }
}

//+------------------------------------------------------------------+
//| Reset daily counters                                              |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime lastDt;
   TimeToStruct(g_lastTradeDay, lastDt);
   
   if(dt.day != lastDt.day || dt.mon != lastDt.mon || dt.year != lastDt.year)
   {
      g_dailyTradeCount = 0;
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_lastTradeDay = TimeCurrent();
      Print("New trading day - counters reset");
   }
}

//+------------------------------------------------------------------+
//| Process daily signals - place pending orders                      |
//+------------------------------------------------------------------+
void ProcessDailySignals()
{
   //--- Check if Friday after no-new-trades cutoff
   if(InpCloseBeforeWeekend)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayNoNewTrades)
      {
         Print("Friday after ", InpFridayNoNewTrades, ":00 - No new trades allowed before weekend");
         return;
      }
   }
   
   //--- Check session filter
   if(InpUseSessionFilter && !IsWithinSession())
   {
      Print("Outside trading session. Skipping order placement.");
      return;
   }
   
   //--- Check spread
   if(!CheckSpread())
   {
      Print("Spread too high. Skipping order placement.");
      return;
   }
   
   //--- Check daily limits
   if(!CheckDailyLimits())
   {
      Print("Daily limits reached. Skipping order placement.");
      return;
   }
   
   //--- Delete existing pending orders first
   DeletePendingOrders();
   
   //--- Get previous daily candle data
   double prevHigh = iHigh(Symbol(), PERIOD_D1, 1);
   double prevLow  = iLow(Symbol(), PERIOD_D1, 1);
   double prevClose = iClose(Symbol(), PERIOD_D1, 1);
   double prevOpen = iOpen(Symbol(), PERIOD_D1, 1);
   
   if(prevHigh == 0 || prevLow == 0)
   {
      Print("Error getting previous day data");
      return;
   }
   
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double offset = InpOrderOffset * point;
   
   //--- Fixed SL distance (300 pips = 3000 points for Gold with 2 decimals, or 30000 for 3 decimals)
   //--- For XAUUSD: 1 pip = 0.1 price movement, so 300 pips = $30
   double fixedSLDistance = InpFixedSLPips * 10 * point;  // Convert pips to price distance
   
   //--- Buy Stop at upper wick (previous high)
   double buyStopPrice = prevHigh + offset;
   double buySL, buyRisk;
   
   if(InpFixedSLPips > 0)
   {
      //--- Use fixed 300 pips SL
      buySL = buyStopPrice - fixedSLDistance;
      buyRisk = fixedSLDistance;
   }
   else
   {
      //--- Use daily range (previous low)
      buySL = prevLow - offset;
      buyRisk = buyStopPrice - buySL;
   }
   double buyTP = buyStopPrice + (buyRisk * InpInitialTPRatio);  // 1:2 RR = 600 pips TP
   
   //--- Sell Stop at lower wick (previous low)
   double sellStopPrice = prevLow - offset;
   double sellSL, sellRisk;
   
   if(InpFixedSLPips > 0)
   {
      //--- Use fixed 300 pips SL
      sellSL = sellStopPrice + fixedSLDistance;
      sellRisk = fixedSLDistance;
   }
   else
   {
      //--- Use daily range (previous high)
      sellSL = prevHigh + offset;
      sellRisk = sellSL - sellStopPrice;
   }
   double sellTP = sellStopPrice - (sellRisk * InpInitialTPRatio);  // 1:2 RR = 600 pips TP
   
   //--- Calculate lot sizes based on 1% risk on 300 pips
   double buyLots = CalculateLotSize(buyRisk);
   double sellLots = CalculateLotSize(sellRisk);
   
   //--- Normalize prices
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   buyStopPrice = NormalizeDouble(buyStopPrice, digits);
   buySL = NormalizeDouble(buySL, digits);
   buyTP = NormalizeDouble(buyTP, digits);
   sellStopPrice = NormalizeDouble(sellStopPrice, digits);
   sellSL = NormalizeDouble(sellSL, digits);
   sellTP = NormalizeDouble(sellTP, digits);
   
   //--- Check minimum stop level
   double minStopLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) * point;
   double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   //--- Place Buy Stop with 1:2 TP (600 pips)
   if(buyStopPrice > currentPrice + minStopLevel && buyLots > 0)
   {
      if(m_trade.BuyStop(buyLots, buyStopPrice, Symbol(), buySL, buyTP, ORDER_TIME_DAY, 0, "GoldBreakout Buy"))
      {
         Print("Buy Stop placed at ", buyStopPrice, " SL: ", buySL, " (", InpFixedSLPips, " pips) TP: ", buyTP, " Lots: ", buyLots);
      }
      else
      {
         Print("Buy Stop failed: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
      }
   }
   else
   {
      Print("Buy Stop price too close to current price or invalid lots");
   }
   
   //--- Place Sell Stop with 1:2 TP (600 pips)
   currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   if(sellStopPrice < currentPrice - minStopLevel && sellLots > 0)
   {
      if(m_trade.SellStop(sellLots, sellStopPrice, Symbol(), sellSL, sellTP, ORDER_TIME_DAY, 0, "GoldBreakout Sell"))
      {
         Print("Sell Stop placed at ", sellStopPrice, " SL: ", sellSL, " (", InpFixedSLPips, " pips) TP: ", sellTP, " Lots: ", sellLots);
      }
      else
      {
         Print("Sell Stop failed: ", m_trade.ResultRetcode(), " - ", m_trade.ResultRetcodeDescription());
      }
   }
   else
   {
      Print("Sell Stop price too close to current price or invalid lots");
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskPoints)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * (InpRiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   
   if(tickValue == 0 || tickSize == 0 || riskPoints == 0)
   {
      Print("Error calculating lot size - invalid values");
      return 0;
   }
   
   //--- Calculate pip value per lot
   double pipValue = tickValue / tickSize * point;
   
   //--- Calculate lots based on risk %
   double lots = riskAmount / (riskPoints / point * pipValue);
   
   //--- Cap lot size based on max loss amount ($50k default)
   if(InpMaxLossAmount > 0)
   {
      double maxLots = InpMaxLossAmount / (riskPoints / point * pipValue);
      if(lots > maxLots)
      {
         lots = maxLots;
         Print("Lot size capped to limit max loss to $", InpMaxLossAmount, " - lots: ", lots);
      }
   }
   
   //--- Reduce lots by 50% on Friday
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpReduceFridayLots && dt.day_of_week == 5)
   {
      lots = lots * 0.5;
      Print("Friday: Lots reduced by 50% to ", lots);
   }
   
   //--- Normalize to lot step
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage open positions - risk-free at 1:1, TP at 1:4              |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;
         
      if(m_position.Symbol() != Symbol())
         continue;
         
      if(m_position.Magic() != InpMagicNumber)
         continue;
      
      ulong ticket = m_position.Ticket();
      double entryPrice = m_position.PriceOpen();
      double currentPrice = m_position.PriceCurrent();
      double sl = m_position.StopLoss();
      double currentLots = m_position.Volume();
      ENUM_POSITION_TYPE posType = m_position.PositionType();
      
      //--- Check if this position is tracked
      int posIndex = FindPositionIndex(ticket);
      
      if(posIndex < 0)
      {
         //--- New position, add to tracking
         AddPositionToTracking(ticket, entryPrice, sl, currentLots, posType == POSITION_TYPE_BUY ? 0 : 1);
         posIndex = FindPositionIndex(ticket);
      }
      
      if(posIndex < 0) continue;
      
      double riskDistance = MathAbs(entryPrice - g_positions[posIndex].originalSL);
      double profitDistance = 0;
      double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double buffer = 50 * point;  // 5 pips = 50 points for Gold
      
      if(posType == POSITION_TYPE_BUY)
         profitDistance = currentPrice - entryPrice;
      else
         profitDistance = entryPrice - currentPrice;
      
      //--- At 1:1 RR - Move SL to breakeven (risk-free)
      if(!g_positions[posIndex].riskFreeSet)
      {
         if(profitDistance >= riskDistance * InpRiskFreeRR)
         {
            double newSL = 0;
            
            if(posType == POSITION_TYPE_BUY)
               newSL = entryPrice + buffer;  // Lock 5 pips profit
            else
               newSL = entryPrice - buffer;  // Lock 5 pips profit
            
            double existingTP = m_position.TakeProfit();
            
            if(m_trade.PositionModify(ticket, newSL, existingTP))
            {
               Print("Risk-free triggered at 1:1 - SL moved to breakeven: ", newSL);
               g_positions[posIndex].riskFreeSet = true;
               g_positions[posIndex].originalSL = newSL;  // Update for trailing
            }
         }
      }
   }
   
   //--- Clean up closed positions from tracking
   CleanupClosedPositions();
}

//+------------------------------------------------------------------+
//| Update trailing stops on H1 timeframe                             |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i))
         continue;
         
      if(m_position.Symbol() != Symbol())
         continue;
         
      if(m_position.Magic() != InpMagicNumber)
         continue;
      
      ulong ticket = m_position.Ticket();
      int posIndex = FindPositionIndex(ticket);
      
      //--- Trail ALL positions immediately (not just after partial close)
      if(posIndex < 0)
         continue;
      
      double currentSL = m_position.StopLoss();
      double currentTP = m_position.TakeProfit();  // Preserve existing TP
      double entryPrice = m_position.PriceOpen();
      ENUM_POSITION_TYPE posType = m_position.PositionType();
      
      //--- Get previous M15 candle data for tighter trailing
      double prevM15High = iHigh(Symbol(), PERIOD_M15, 1);
      double prevM15Low = iLow(Symbol(), PERIOD_M15, 1);
      
      if(prevM15High == 0 || prevM15Low == 0)
         continue;
      
      double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double minStopLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) * point;
      int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
      
      double newSL = 0;
      double currentPrice = 0;
      bool inProfit = false;
      
      //--- Check if position is in profit before trailing
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         inProfit = (currentPrice > entryPrice);
      }
      else
      {
         currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         inProfit = (currentPrice < entryPrice);
      }
      
      //--- Only trail when position is in profit
      if(!inProfit)
         continue;
      
      if(posType == POSITION_TYPE_BUY)
      {
         //--- Trail SL below previous M15 low
         newSL = NormalizeDouble(prevM15Low - point, digits);
         
         //--- Only move SL up, never down
         if(newSL > currentSL)
         {
            if(currentPrice - newSL > minStopLevel)
            {
               if(m_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Trailing SL updated for BUY #", ticket, " to ", newSL);
               }
            }
         }
      }
      else // SELL
      {
         //--- Trail SL above previous M15 high
         newSL = NormalizeDouble(prevM15High + point, digits);
         
         //--- Only move SL down, never up
         if(newSL < currentSL)
         {
            if(newSL - currentPrice > minStopLevel)
            {
               if(m_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Trailing SL updated for SELL #", ticket, " to ", newSL);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Position tracking functions                                       |
//+------------------------------------------------------------------+
int FindPositionIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_positions); i++)
   {
      if(g_positions[i].ticket == ticket)
         return i;
   }
   return -1;
}

void AddPositionToTracking(ulong ticket, double entry, double sl, double lots, int type)
{
   int size = ArraySize(g_positions);
   ArrayResize(g_positions, size + 1);
   g_positions[size].ticket = ticket;
   g_positions[size].entryPrice = entry;
   g_positions[size].originalSL = sl;
   g_positions[size].originalLots = lots;
   g_positions[size].riskDistance = MathAbs(entry - sl);  // Store risk distance
   g_positions[size].riskFreeSet = false;
   g_positions[size].partialClosed = false;
   g_positions[size].positionType = type;
   
   Print("Position tracked: Ticket #", ticket, " Entry: ", entry, " SL: ", sl, " Lots: ", lots);
   g_dailyTradeCount++;
}

void CleanupClosedPositions()
{
   PositionData tempPositions[];
   int count = 0;
   
   for(int i = 0; i < ArraySize(g_positions); i++)
   {
      bool found = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         if(m_position.SelectByIndex(j))
         {
            if(m_position.Ticket() == g_positions[i].ticket)
            {
               found = true;
               break;
            }
         }
      }
      
      if(found)
      {
         ArrayResize(tempPositions, count + 1);
         tempPositions[count] = g_positions[i];
         count++;
      }
   }
   
   ArrayFree(g_positions);
   ArrayResize(g_positions, count);
   for(int i = 0; i < count; i++)
   {
      g_positions[i] = tempPositions[i];
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders for this EA                             |
//+------------------------------------------------------------------+
void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!m_order.SelectByIndex(i))
         continue;
         
      if(m_order.Symbol() != Symbol())
         continue;
         
      if(m_order.Magic() != InpMagicNumber)
         continue;
      
      if(m_order.OrderType() == ORDER_TYPE_BUY_STOP || m_order.OrderType() == ORDER_TYPE_SELL_STOP)
      {
         if(m_trade.OrderDelete(m_order.Ticket()))
         {
            Print("Pending order deleted: ", m_order.Ticket());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check spread                                                      |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
   {
      Print("Spread too high: ", spread, " > ", InpMaxSpread);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if within trading session                                   |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   if(InpSessionStartHour <= InpSessionEndHour)
   {
      return (hour >= InpSessionStartHour && hour <= InpSessionEndHour);
   }
   else
   {
      return (hour >= InpSessionStartHour || hour <= InpSessionEndHour);
   }
}

//+------------------------------------------------------------------+
//| Check daily limits                                                |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   //--- Check max daily trades
   if(InpMaxDailyTrades > 0 && g_dailyTradeCount >= InpMaxDailyTrades)
   {
      Print("Max daily trades reached: ", g_dailyTradeCount);
      return false;
   }
   
   //--- Check max daily loss
   if(InpMaxDailyLoss > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double lossPercent = ((g_dailyStartBalance - currentBalance) / g_dailyStartBalance) * 100;
      
      if(lossPercent >= InpMaxDailyLoss)
      {
         Print("Max daily loss reached: ", lossPercent, "%");
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
