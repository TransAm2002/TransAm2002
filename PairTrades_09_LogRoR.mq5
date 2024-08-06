//+------------------------------------------------------------------+
//|                                   CointegrationVolatilityEA.mq5  |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.08"

input string pair1 = "US500Cash";      // 第1の通貨ペア
input string pair2 = "US2000Cash";     // 第2の通貨ペア
input int lookback_period = 100;       // データの参照期間
input double upper_threshold = 2.0;    // スプレッドの上限閾値
input double lower_threshold = -2.0;   // スプレッドの下限閾値
input double total_lot_size = 1.0;     // 合計ロットサイズ
input double max_drawdown = 50.0;      // 最大ドローダウン (%)
input int volatility_period = 20;      // ボラティリティ計算期間
input ENUM_TIMEFRAMES timeframe = PERIOD_CURRENT; // 使用する時間枠

// 変数の宣言
double price1[];
double price2[];
double spread[];
double spread_mean;
double spread_std;
double account_initial_balance;
double current_drawdown;
int open_positions_count;
double current_z_score;
double pair1_lot;
double pair2_lot;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   ArraySetAsSeries(price1, true);
   ArraySetAsSeries(price2, true);
   ArraySetAsSeries(spread, true);

   ArrayResize(price1, lookback_period);
   ArrayResize(price2, lookback_period);
   ArrayResize(spread, lookback_period);

   account_initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // シンボルの存在確認
   if(!SymbolSelect(pair1, true) || !SymbolSelect(pair2, true))
     {
      Print("Error: One or both symbols are not available.");
      return INIT_FAILED;
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // クリーンアップ処理
   ArrayFree(price1);
   ArrayFree(price2);
   ArrayFree(spread);
   Comment(""); // コメントをクリア
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   CalculateVolatilityBasedLotSizes();
   
   open_positions_count = GetOpenPositionsCount();
   /*
   if(open_positions_count >= 2)
     {
      // オープンポジションが2つ以上ある場合は新規ポジションを開かない
      UpdateChartComment();
      ChartRedraw();
      return;
     }
   */
   if(!CopyClose(pair1, timeframe, 0, lookback_period, price1) ||
      !CopyClose(pair2, timeframe, 0, lookback_period, price2))
     {
      Print("Failed to copy price data");
      return;
     }

   for(int i = 0; i < lookback_period; i++)
     {
      spread[i] = price1[i] - price2[i];
     }

   spread_mean = CalculateMean(spread, lookback_period);
   spread_std = CalculateStdDev(spread, spread_mean, lookback_period);

   double current_spread = spread[0];
   current_z_score = (current_spread - spread_mean) / spread_std;

   // ニュートラルゾーンの定義（例：閾値の絶対値の半分）
   double neutral_zone = MathMin(MathAbs(upper_threshold), MathAbs(lower_threshold)) / 2;

   // 決済ロジック：Zスコアがニュートラルゾーン内に入った場合にポジションを決済
   if(MathAbs(current_z_score) <= neutral_zone)
     {
      if(open_positions_count > 0)
        {
         CloseAllPositions();
         Print("Z-Score entered neutral zone. All positions closed.");
        }
     }
   else if(current_z_score > upper_threshold && open_positions_count < 2)
     {
      if(CheckMargin(pair1, pair1_lot, ORDER_TYPE_SELL) && CheckMargin(pair2, pair2_lot, ORDER_TYPE_BUY))
        {
         CloseAllPositions(); // 既存のポジションをクローズ
         if(SendOrder(pair1, ORDER_TYPE_SELL, pair1_lot) && SendOrder(pair2, ORDER_TYPE_BUY, pair2_lot))
           {
            Print("Trade executed: Sell ", pair1, ", Buy ", pair2);
           }
        }
     }
   else if(current_z_score < lower_threshold && open_positions_count < 2)
     {
      if(CheckMargin(pair1, pair1_lot, ORDER_TYPE_BUY) && CheckMargin(pair2, pair2_lot, ORDER_TYPE_SELL))
        {
         CloseAllPositions(); // 既存のポジションをクローズ
         if(SendOrder(pair1, ORDER_TYPE_BUY, pair1_lot) && SendOrder(pair2, ORDER_TYPE_SELL, pair2_lot))
           {
            Print("Trade executed: Buy ", pair1, ", Sell ", pair2);
           }
        }
     }

   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   current_drawdown = 100.0 * (account_initial_balance - account_balance) / account_initial_balance;
   if(current_drawdown > max_drawdown)
     {
      CloseAllPositions();
      Print("Max drawdown exceeded. All positions closed.");
     }

   UpdateChartComment();
   ChartRedraw();  // チャートの強制再描画
  }

//+------------------------------------------------------------------+
//| ボリュームを正規化する関数                                       |
//+------------------------------------------------------------------+
double NormalizeVolume(string symbol, double volume)
  {
   double min_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   volume = MathMax(volume, min_volume);
   volume = MathMin(volume, max_volume);
   volume = MathRound(volume / volume_step) * volume_step;

   return volume;
  }

//+------------------------------------------------------------------+
//| ボラティリティに基づくロットサイズの計算                         |
//+------------------------------------------------------------------+
void CalculateVolatilityBasedLotSizes()
  {
   MqlRates rates1[], rates2[];
   ArraySetAsSeries(rates1, true);
   ArraySetAsSeries(rates2, true);
   
   if(CopyRates(pair1, PERIOD_D1, 0, volatility_period+1, rates1) != volatility_period+1 ||
      CopyRates(pair2, PERIOD_D1, 0, volatility_period+1, rates2) != volatility_period+1)
     {
      Print("Error copying price data for volatility calculation");
      return;
     }

   double returns1[], returns2[];
   ArrayResize(returns1, volatility_period);
   ArrayResize(returns2, volatility_period);
   
   for(int i=0; i<volatility_period; i++)
     {
      returns1[i] = MathLog(rates1[i].close / rates1[i+1].close);
      returns2[i] = MathLog(rates2[i].close / rates2[i+1].close);
     }

   double volatility1 = CalculateStdDev(returns1, CalculateMean(returns1, volatility_period), volatility_period);
   double volatility2 = CalculateStdDev(returns2, CalculateMean(returns2, volatility_period), volatility_period);

   double inverse_vol1 = 1.0 / volatility1;
   double inverse_vol2 = 1.0 / volatility2;
   double total_inverse_vol = inverse_vol1 + inverse_vol2;

   pair1_lot = NormalizeVolume(pair1, total_lot_size * (inverse_vol1 / total_inverse_vol));
   pair2_lot = NormalizeVolume(pair2, total_lot_size * (inverse_vol2 / total_inverse_vol));
  }

//+------------------------------------------------------------------+
//| チャートコメントを更新する関数                                   |
//+------------------------------------------------------------------+
void UpdateChartComment()
  {
   string comment = "";
   StringConcatenate(comment,
                     "Pair 1: ", pair1, " (Lot: ", DoubleToString(pair1_lot, 2), ")\n",
                     "Pair 2: ", pair2, " (Lot: ", DoubleToString(pair2_lot, 2), ")\n",
                     "Current Z-Score: ", DoubleToString(current_z_score, 2), "\n",
                     "Open Positions: ", IntegerToString(open_positions_count), "\n",
                     "Current Drawdown: ", DoubleToString(current_drawdown, 2), "%\n",
                     "Spread Mean: ", DoubleToString(spread_mean, 5), "\n",
                     "Spread Std Dev: ", DoubleToString(spread_std, 5), "\n"
                    );

   Comment(comment);
  }

//+------------------------------------------------------------------+
//| オープンポジションの数を取得する関数                             |
//+------------------------------------------------------------------+
int GetOpenPositionsCount()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(symbol == pair1 || symbol == pair2)
           {
            count++;
           }
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| 全ポジションを決済する関数                                       |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(symbol == pair1 || symbol == pair2)
           {
            double volume = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            MqlTradeRequest request;
            MqlTradeResult result;
            ZeroMemory(request);
            ZeroMemory(result);

            request.action = TRADE_ACTION_DEAL;
            request.position = ticket;
            request.symbol = symbol;
            request.volume = volume;
            request.type = type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = type == POSITION_TYPE_BUY ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
            request.deviation = 5;

            // フィリングモードの設定
            long filling_modes;
            if(!SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE, filling_modes))
              {
               Print("Failed to get filling mode for ", symbol);
               continue;
              }

            if(filling_modes & SYMBOL_FILLING_FOK)
               request.type_filling = ORDER_FILLING_FOK;
            else if(filling_modes & SYMBOL_FILLING_IOC)
               request.type_filling = ORDER_FILLING_IOC;
            else
               request.type_filling = ORDER_FILLING_RETURN;

            if(!OrderSend(request, result))
              {
               Print("OrderSend error: ", GetLastError());
              }
            else if(result.retcode == TRADE_RETCODE_DONE)
              {
               Print("Position closed successfully: ", result.deal);
              }
            else
              {
               Print("Position closing failed with retcode: ", result.retcode);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| マージンチェックの関数                                           |
//+------------------------------------------------------------------+
bool CheckMargin(string symbol, double volume, ENUM_ORDER_TYPE order_type)
  {
   double margin_required = 0.0;
   if(!OrderCalcMargin(order_type, symbol, volume, SymbolInfoDouble(symbol, SYMBOL_ASK), margin_required))
     {
      Print("Error in OrderCalcMargin: ", GetLastError());
      return false;
     }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return free_margin >= margin_required;
  }

//+------------------------------------------------------------------+
//| スプレッドの平均値を計算する関数                                 |
//+------------------------------------------------------------------+
double CalculateMean(const double &array[], int size)
  {
   if(size <= 0) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < size; i++)
     {
      sum += array[i];
     }
   return sum / size;
  }

//+------------------------------------------------------------------+
//| スプレッドの標準偏差を計算する関数                               |
//+------------------------------------------------------------------+
double CalculateStdDev(const double &array[], double mean, int size)
  {
   if(size <= 1) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < size; i++)
     {
      sum += MathPow(array[i] - mean, 2);
     }
   return MathSqrt(sum / (size - 1));
  }

//+------------------------------------------------------------------+
//| 取引オーダーを送信する関数                                       |
//+------------------------------------------------------------------+
bool SendOrder(string symbol, ENUM_ORDER_TYPE type, double volume)
  {
   volume = NormalizeVolume(symbol, volume);

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.volume = volume;
   request.type = type;
   request.price = type == ORDER_TYPE_BUY ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   request.deviation = 5;
   request.magic = 123456;
   request.comment = "Cointegration Trade";

   // フィリングモードの設定
   long filling_modes;
   if(!SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE, filling_modes))
     {
      Print("Failed to get filling mode for ", symbol);
      return false;
     }

   if(filling_modes & SYMBOL_FILLING_FOK)
      request.type_filling = ORDER_FILLING_FOK;
   else if(filling_modes & SYMBOL_FILLING_IOC)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(request, result))
     {
      Print("OrderSend error: ", GetLastError());
      return false;
     }

   if(result.retcode == TRADE_RETCODE_DONE)
     {
      Print("Order executed successfully: ", result.deal);
      return true;
     }
   else
     {
      Print("Order failed with retcode: ", result.retcode);
      return false;
     }
  }