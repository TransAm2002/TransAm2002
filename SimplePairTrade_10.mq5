//+------------------------------------------------------------------+
//|                                              CointegrationVolatilityEA.mq5 |
//|                        Copyright 2024, MetaTrader 5 User               |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

input string pair1 = "US500Cash";         // 第1の通貨ペア
input string pair2 = "US2000Cash";        // 第2の通貨ペア
input double exposure = 1.0;              // 1ポジションあたりの露出額
input double total_lot_size = 1.0;        // 合計ロットサイズ
input int lookback_period = 20;           // データの参照期間
input double upper_threshold = 2.0;       // スプレッドの上限閾値
input double lower_threshold = -2.0;      // スプレッドの下限閾値
input double max_drawdown = 50.0;         // 最大ドローダウン（%）
input ENUM_TIMEFRAMES timeframe = PERIOD_D1; // 使用する時間枠
input ENUM_TIMEFRAMES zScoreTimeframe = PERIOD_D1; // Zスコア計算用の時間枠
input int MagicNumber = 123456;           // EAの識別用マジックナンバー

double spread_value = 0.0, zScore = 0.0, avgSpread = 0.0, stddevSpread = 0.0;
double lot1 = 0.0, lot2 = 0.0;
double currentDrawdown = 0.0;

CTrade trade;

//+------------------------------------------------------------------+
//| 初期化処理                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
    MqlTick tick1, tick2;
    if (!SymbolInfoTick(pair1, tick1) || !SymbolInfoTick(pair2, tick2))
    {
        Print("One or both symbols are unavailable.");
        return INIT_FAILED;
    }
    return INIT_SUCCEEDED;
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
//| Rate of Change (RoC) の計算                                     |
//+------------------------------------------------------------------+
double CalculateRoC(string symbol, int period)
{
    double priceNow = iClose(symbol, timeframe, 0);
    double pricePast = iClose(symbol, timeframe, period);
    return (priceNow - pricePast) / pricePast * 100;
}

//+------------------------------------------------------------------+
//| ボラティリティの計算                                             |
//+------------------------------------------------------------------+
double CalculateVolatility(string symbol, int lookback_period)
{
    return iStdDev(symbol, timeframe, lookback_period, 0, MODE_SMA, PRICE_CLOSE);
}

//+------------------------------------------------------------------+
//| Pips Value の計算                                              |
//+------------------------------------------------------------------+
double CalculatePipValue(string symbol)
{
    double pip_value = 0.0;
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double lot_size = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN); // 最小ロットサイズ

    if (point > 0 && lot_size > 0)
    {
        pip_value = point * lot_size * SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
    }
    
    return pip_value;
}

//+------------------------------------------------------------------+
//| logRoR の計算                                                   |
//+------------------------------------------------------------------+
double CalculateLogRoR(string symbol, int period)
{
    double logRoR = 0.0;
    for (int i = 1; i < period; i++)
    {
        double priceNow = iClose(symbol, timeframe, i);
        double pricePrev = iClose(symbol, timeframe, i + 1);
        logRoR += log(priceNow / pricePrev);
    }
    return logRoR / period;
}

//+------------------------------------------------------------------+
//| ロットサイズの計算                                               |
//+------------------------------------------------------------------+
void CalculateLotSize()
{
    // 各ペアのPips Value を計算
    double pip_value1 = CalculatePipValue(pair1);
    double pip_value2 = CalculatePipValue(pair2);

    // 各ペアの logRoR を計算
    double logRoR1 = CalculateLogRoR(pair1, lookback_period);
    double logRoR2 = CalculateLogRoR(pair2, lookback_period);

    // 合計Pips Valueを計算
    double total_value = pip_value1 + pip_value2;

    // ロットサイズを計算
    double lot_ratio1 = logRoR1 / (logRoR1 + logRoR2);
    double lot_ratio2 = logRoR2 / (logRoR1 + logRoR2);

    lot1 = (total_lot_size * lot_ratio1 * pip_value1) / total_value;
    lot2 = (total_lot_size * lot_ratio2 * pip_value2) / total_value;

    // ロットサイズを正規化
    lot1 = NormalizeVolume(pair1, lot1);
    lot2 = NormalizeVolume(pair2, lot2);
}

//+------------------------------------------------------------------+
//| 移動平均の手動計算                                               |
//+------------------------------------------------------------------+
double CalculateSMA(double &array[], int period)
{
    double sum = 0.0;
    for (int i = 0; i < period; i++)
    {
        sum += array[i];
    }
    return sum / period;
}

//+------------------------------------------------------------------+
//| 標準偏差の手動計算                                               |
//+------------------------------------------------------------------+
double CalculateStdDev(double &array[], int period, double mean)
{
    double sum = 0.0;
    for (int i = 0; i < period; i++)
    {
        sum += MathPow(array[i] - mean, 2);
    }
    // サンプル標準偏差の計算: N-1で割る
    return MathSqrt(sum / (period - 1));
}


//+------------------------------------------------------------------+
//| Zスコアの計算                                                    |
//+------------------------------------------------------------------+
double CalculateZScore(double spread, ENUM_TIMEFRAMES zScoreTimeframe, int lookback_period)
{
    double spread_array[];
    ArrayResize(spread_array, lookback_period + 1);  // 最新のスプレッドも含めるために+1
    
    // 過去のスプレッドを配列に追加
    for (int i = 0; i < lookback_period; i++)
    {
        spread_array[i] = iClose(pair1, zScoreTimeframe, i) - iClose(pair2, zScoreTimeframe, i);
    }
    spread_array[lookback_period] = spread; // 最新のスプレッドを追加

    // 新しいzScoreLookbackPeriod + 1に基づいて平均と標準偏差を計算
    avgSpread = CalculateSMA(spread_array, lookback_period + 1);
    stddevSpread = CalculateStdDev(spread_array, lookback_period + 1, avgSpread);

    // 最新のスプレッドに基づいてzスコアを計算
    return (spread - avgSpread) / stddevSpread;
}


//+------------------------------------------------------------------+
//| オーダー送信                                                     |
//+------------------------------------------------------------------+
void SendOrder(string symbol, int orderType, double volume)
{
    volume = NormalizeVolume(symbol, volume);

    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request);
    ZeroMemory(result);

    // シンボルのサポートされているフィリングモードを確認
    long filling_modes;
    if (!SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE, filling_modes))
    {
        Print("Failed to get filling mode for ", symbol);
        return;
    }

    if (filling_modes & SYMBOL_FILLING_FOK)
        request.type_filling = ORDER_FILLING_FOK;
    else if (filling_modes & SYMBOL_FILLING_IOC)
        request.type_filling = ORDER_FILLING_IOC;
    else
        request.type_filling = ORDER_FILLING_RETURN;

    request.action = TRADE_ACTION_DEAL;
    request.symbol = symbol;
    request.volume = volume;
    request.type = orderType;
    request.price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
    request.deviation = 10;
    request.magic = MagicNumber;
    request.comment = "CointegrationVolatilityEA";

    if (!OrderSend(request, result))
    {
        Print("OrderSend failed: ", GetLastError());
    }
    else
    {
        Print("OrderSend succeeded for ", symbol);
    }
}

//+------------------------------------------------------------------+
//| 全ポジションのクローズ                                           |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (!trade.PositionClose(ticket))
        {
            Print("Failed to close position: ", ticket);
        }
    }
}

//+------------------------------------------------------------------+
//| ドローダウンチェック                                              |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    currentDrawdown = 100.0 * (balance - equity) / balance;

    if (currentDrawdown >= max_drawdown)
    {
        CloseAllPositions();
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| チャートに主な変数を表示する                                     |
//+------------------------------------------------------------------+
void DisplayVariables()
{
    // 変数をチャートに表示するテキストを作成
    string display_text = "Pair 1: " + pair1 + "\n"
                          + "Pair 2: " + pair2 + "\n"
                          + "Spread: " + DoubleToString(spread_value, Digits()) + "\n"
                          + "Z-Score: " + DoubleToString(zScore, 2) + "\n"
                          + "Lot1: " + DoubleToString(lot1, 2) + "\n"
                          + "Lot2: " + DoubleToString(lot2, 2) + "\n"
                          + "Current Drawdown: " + DoubleToString(currentDrawdown, 2) + "%\n"
                          + "Avg Spread: " + DoubleToString(avgSpread, Digits()) + "\n"
                          + "Std Dev Spread: " + DoubleToString(stddevSpread, 2);

    // チャートに表示
    Comment(display_text);
}

//+------------------------------------------------------------------+
//| EAのメインロジック                                                |
//+------------------------------------------------------------------+
void OnTick()
{
    // 必要な変数の計算
    double price1 = iClose(pair1, timeframe, 0);
    double price2 = iClose(pair2, timeframe, 0);
    spread_value = price1 - price2;

    // 入力パラメータからタイムフレームと期間を指定してzScoreを計算
    zScore = CalculateZScore(spread_value, zScoreTimeframe, lookback_period);

    if (CheckDrawdown())
        return;

    if (PositionsTotal() == 0)
    {
        CalculateLotSize();

        if (zScore > upper_threshold)
        {
            SendOrder(pair1, ORDER_TYPE_SELL, lot1);
            SendOrder(pair2, ORDER_TYPE_BUY, lot2 * 2);
        }
        else if (zScore < lower_threshold)
        {
            SendOrder(pair1, ORDER_TYPE_BUY, lot1);
            SendOrder(pair2, ORDER_TYPE_SELL, lot2 * 2);
        }
    }
    else
    {
        if (zScore > lower_threshold && zScore < upper_threshold)
        {
            CloseAllPositions();
        }
    }

    // 変数を表示
    DisplayVariables();
}

//+------------------------------------------------------------------+
//| 終了処理                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    CloseAllPositions();
    Print("CointegrationVolatilityEA stopped.");
}

//+------------------------------------------------------------------+
