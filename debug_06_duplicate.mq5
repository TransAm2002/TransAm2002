//+------------------------------------------------------------------+
//|                                                    HedgeTrader.mq5|
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                       http://www.metaquotes.net/ |
//+------------------------------------------------------------------+
#property strict

input double HedgeStartPrice = -3000.0;           // ヘッジオーダー発行の基準となる浮動利益
datetime lastCheckTime = 0; // Variable to store the time of the last checked candle
input double Exposure = 0.11;                  // ヘッジオーダーのロット数
input int MagicNumber = 123456;               // Magic Number
input double MaxLossPercentage = 50.0;        // 口座資金の50%まで含み損が増えたら全決済
input bool DebugMode = true;                 // デバッグコードのON/OFF
input int SpreadFilter = 20;               // 主要通貨スプレッド

// グローバル変数
double AccountEquity;
double MaxAllowedLoss;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Initialization code
   lastCheckTime = iTime(Symbol(), PERIOD_M1, 0); // Initialize with the time of the last 5-minute candle
   // 初期化処理
   AccountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   MaxAllowedLoss = AccountEquity * MaxLossPercentage / 100.0;

   if (DebugMode)
     Print("Initialization Complete. Max Allowed Loss: ", MaxAllowedLoss);

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // EAのクリーンアップ処理
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime currentTime = iTime(Symbol(), PERIOD_M1, 0); // Get the time of the last 5-minute candle

   double totalLoss = 0.0;
   bool hedgeNeeded = false;
   int totalOrders = PositionsTotal();

   if (currentTime != lastCheckTime)
     {
      lastCheckTime = currentTime; // Update the last check time
   if (CheckSpreads())
   {
   for (int i = totalOrders - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket))
        {
         double floatingProfit = PositionGetDouble(POSITION_PROFIT);
         string symbol = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE orderType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         int magicNumber = (int)PositionGetInteger(POSITION_MAGIC);
         double lotSize = PositionGetDouble(POSITION_VOLUME);

         if (floatingProfit < HedgeStartPrice)
           {
            hedgeNeeded = true;
            if (DebugMode)
              Print("Hedge Needed for Symbol: ", symbol, " with Floating Profit: ", floatingProfit);
           }

         if (hedgeNeeded)
           {
            lotSize = Exposure; // ロット数はExposureで設定される
            if (SendHedgeOrder(symbol, lotSize, orderType, magicNumber))
              {
               if (DebugMode)
                 Print("Hedge Order Sent for Symbol: ", symbol, " with Lot Size: ", lotSize);
              }
            else
              {
               if (DebugMode)
                 Print("Failed to Send Hedge Order for Symbol: ", symbol);
              }
           }

         totalLoss += floatingProfit;
        }
     }
     }
     }

   if (totalLoss < -MaxAllowedLoss)
     {
      CloseAllOrders();
      if (DebugMode)
        Print("Max Loss Exceeded. All Orders Closed.");
     }
  }
//+------------------------------------------------------------------+
//| Check if the order is already hedged                             |
//+------------------------------------------------------------------+
bool IsHedged(string symbol, ulong originalTicket)
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelect(ticket))
        {
         string hedgeSymbol = PositionGetString(POSITION_SYMBOL);
         string hedgeComment = PositionGetString(POSITION_COMMENT);
         if(hedgeSymbol == symbol && hedgeComment == "Hedge for ticket " + IntegerToString(originalTicket))
           {
            return true;
           }
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
//| Function to send a hedge order                                  |
//+------------------------------------------------------------------+
bool SendHedgeOrder(string symbol, double lotSize, ENUM_POSITION_TYPE orderType, int magicNumber)

  {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.type = (orderType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY; // 反対の注文
   request.symbol = symbol;
   request.volume = lotSize;
   request.type_filling = ORDER_FILLING_IOC;
   request.price = (orderType == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
   request.deviation = 10;
   request.magic = magicNumber;

   request.type_time = ORDER_TIME_GTC;

   if (!OrderSend(request, result))
     {
      Print("OrderSend failed. Error: ", GetLastError());
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
//| Function to close all orders                                    |
//+------------------------------------------------------------------+
void CloseAllOrders()
  {
   int totalOrders = PositionsTotal();
   for (int i = totalOrders - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket))
        {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};

         request.action = TRADE_ACTION_DEAL;
         request.symbol = PositionGetString(POSITION_SYMBOL);
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY; // 反対の注文
         request.price = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? SymbolInfoDouble(request.symbol, SYMBOL_BID) : SymbolInfoDouble(request.symbol, SYMBOL_ASK);
         request.deviation = 10;
         request.type_filling = ORDER_FILLING_RETURN;
         request.type_time = ORDER_TIME_GTC;

         if (!OrderSend(request, result))
           {
            Print("OrderSend failed. Error: ", GetLastError());
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Check spreads function                                           |
//+------------------------------------------------------------------+
bool CheckSpreads()
  {
   // Get the spread in points for USDJPY, EURUSD, and AUDUSD
   double spreadUSDJPY = SymbolInfoDouble("USDJPY#", SYMBOL_ASK) - SymbolInfoDouble("USDJPY#", SYMBOL_BID);
   double spreadEURUSD = SymbolInfoDouble("EURUSD#", SYMBOL_ASK) - SymbolInfoDouble("EURUSD#", SYMBOL_BID);
   double spreadAUDUSD = SymbolInfoDouble("AUDUSD#", SYMBOL_ASK) - SymbolInfoDouble("AUDUSD#", SYMBOL_BID);

   // Convert the spreads to points
   double spreadUSDJPYPoints = spreadUSDJPY * 1000; // USDJPY typically uses 3 decimal places
   double spreadEURUSDPoints = spreadEURUSD * 100000; // EURUSD typically uses 5 decimal places
   double spreadAUDUSDPoints = spreadAUDUSD * 100000; // AUDUSD typically uses 5 decimal places

   // Check if all spreads are less than 20 points
   if(spreadUSDJPYPoints < SpreadFilter && spreadEURUSDPoints < SpreadFilter && spreadAUDUSDPoints < SpreadFilter)
     {
      return true;
     }
   else
     {
      Print("Spreads too high: USDJPY#: ", spreadUSDJPYPoints, " EURUSD#: ", spreadEURUSDPoints, " AUDUSD#: ", spreadAUDUSDPoints);
      return false;
     }
  }
//+------------------------------------------------------------------+
