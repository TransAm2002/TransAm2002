﻿#property copyright "Copyright 2024, Pair Trading EA"
#property link      "https://www.example.com"
#property version   "1.08"
#property strict

#include <Trade\Trade.mqh>

// Input parameters
input string   BaseSymbol = "US500Cash";
input int      LookbackPeriod = 100;
input double   BaseEntryThreshold = 2.0;
input double   BaseExitThreshold = 0.5;
input double   Exposure = 20.0; // Percentage of free margin to use
input int      ThresholdAdjustPeriod = 20; // Period for threshold adjustment

// Global variables
double basePrice[];
double currentPrice[];
double meanBase, meanCurrent;
double covariance, varBase, varCurrent;
CTrade trade;
string currentSymbol;
double scaleFactor = 1.0;
double correlations[];
double entryThreshold, exitThreshold;
datetime lastEntryTime = 0;
int barCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   currentSymbol = Symbol();
   
   // Check if symbols exist
   if(!SymbolSelect(BaseSymbol, true) || !SymbolSelect(currentSymbol, true))
   {
      Print("Error: One or both symbols do not exist!");
      return INIT_FAILED;
   }
   
   ArrayResize(basePrice, LookbackPeriod);
   ArrayResize(currentPrice, LookbackPeriod);
   ArrayResize(correlations, ThresholdAdjustPeriod);
   
   // Calculate initial scale factor
   double baseInitialPrice = SymbolInfoDouble(BaseSymbol, SYMBOL_BID);
   double currentInitialPrice = SymbolInfoDouble(currentSymbol, SYMBOL_BID);
   scaleFactor = baseInitialPrice / currentInitialPrice;
   
   // Initialize thresholds
   entryThreshold = BaseEntryThreshold;
   exitThreshold = BaseExitThreshold;
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up any resources if necessary
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 新しいバーの開始時のみ処理を行う
   if(IsNewBar())
   {
      barCount++;
      
      // 価格データの更新
      UpdatePriceArrays();
      
      // 相関係数の計算
      double correlation = CalculateCorrelation();
      
      // 相関係数配列の更新
      UpdateCorrelationArray(correlation);
      
      // 閾値の調整
      AdjustThresholds();
      
      // トレーディングロジック
      if(!HasOpenPositions() && CanEnterTrade())
      {
         if(correlation > -entryThreshold && correlation < entryThreshold)
         {
            // 相関が弱まっている、平均回帰の可能性
            if(basePrice[0] > currentPrice[0])
            {
               // BaseSymbolが相対的に割高
               OpenPairTrade(ORDER_TYPE_SELL, ORDER_TYPE_BUY);
            }
            else
            {
               // BaseSymbolが相対的に割安
               OpenPairTrade(ORDER_TYPE_BUY, ORDER_TYPE_SELL);
            }
            lastEntryTime = TimeTradeServer();
         }
      }
      
      // イグジット条件のチェック
      if(MathAbs(correlation) > exitThreshold && HasOpenPositions())
      {
         // 相関が強まった、イグジット
         CloseAllPositions();
      }
   }
}

//+------------------------------------------------------------------+
//| 新しいバーの開始かどうかをチェック                               |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(Symbol(), PERIOD_CURRENT, 0);
   
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 価格データの配列を更新                                           |
//+------------------------------------------------------------------+
void UpdatePriceArrays()
{
   for(int i = LookbackPeriod - 1; i > 0; i--)
   {
      basePrice[i] = basePrice[i-1];
      currentPrice[i] = currentPrice[i-1];
   }
   basePrice[0] = SymbolInfoDouble(BaseSymbol, SYMBOL_BID);
   currentPrice[0] = SymbolInfoDouble(currentSymbol, SYMBOL_BID) * scaleFactor;
}

//+------------------------------------------------------------------+
//| 相関係数を計算                                                   |
//+------------------------------------------------------------------+
double CalculateCorrelation()
{
   // 平均の計算
   meanBase = 0;
   meanCurrent = 0;
   for(int i = 0; i < LookbackPeriod; i++)
   {
      meanBase += basePrice[i];
      meanCurrent += currentPrice[i];
   }
   meanBase /= LookbackPeriod;
   meanCurrent /= LookbackPeriod;
   
   // 共分散と分散の計算
   covariance = 0;
   varBase = 0;
   varCurrent = 0;
   for(int i = 0; i < LookbackPeriod; i++)
   {
      double diffBase = basePrice[i] - meanBase;
      double diffCurrent = currentPrice[i] - meanCurrent;
      covariance += diffBase * diffCurrent;
      varBase += diffBase * diffBase;
      varCurrent += diffCurrent * diffCurrent;
   }
   covariance /= LookbackPeriod;
   varBase /= LookbackPeriod;
   varCurrent /= LookbackPeriod;
   
   // 相関係数の計算
   return covariance / (MathSqrt(varBase) * MathSqrt(varCurrent));
}

//+------------------------------------------------------------------+
//| 相関係数配列を更新                                               |
//+------------------------------------------------------------------+
void UpdateCorrelationArray(double correlation)
{
   for(int i = ThresholdAdjustPeriod - 1; i > 0; i--)
   {
      correlations[i] = correlations[i-1];
   }
   correlations[0] = correlation;
}

//+------------------------------------------------------------------+
//| Adjust entry and exit thresholds                                 |
//+------------------------------------------------------------------+
void AdjustThresholds()
{
   double sum = 0;
   double sumSquared = 0;
   
   for(int i = 0; i < ThresholdAdjustPeriod; i++)
   {
      sum += correlations[i];
      sumSquared += correlations[i] * correlations[i];
   }
   
   double mean = sum / ThresholdAdjustPeriod;
   double variance = (sumSquared / ThresholdAdjustPeriod) - (mean * mean);
   double stdDev = MathSqrt(variance);
   
   // Adjust thresholds based on standard deviation
   entryThreshold = BaseEntryThreshold * (1 + stdDev);
   exitThreshold = BaseExitThreshold * (1 + stdDev);
   
   // Ensure exit threshold is always less than entry threshold
   if(exitThreshold >= entryThreshold)
   {
      exitThreshold = entryThreshold * 0.5;
   }
}

//+------------------------------------------------------------------+
//| トレードエントリーが可能かチェック                               |
//+------------------------------------------------------------------+
bool CanEnterTrade()
{
   datetime currentTime = TimeTradeServer();
   
   // 最後のエントリーから一定時間（例：4時間）経過しているかチェック
   if(currentTime - lastEntryTime < 4 * 3600)
   {
      return false;
   }
   
   // その他のエントリー条件をここに追加
   // 例: 特定の時間帯のみトレード、ニュース時間を避ける、など
   
   return true;
}

//+------------------------------------------------------------------+
//| ペアトレードを開く                                               |
//+------------------------------------------------------------------+
void OpenPairTrade(ENUM_ORDER_TYPE baseOrderType, ENUM_ORDER_TYPE currentOrderType)
{
   double lotBase = CalculateLotSize(BaseSymbol);
   double lotCurrent = CalculateLotSize(currentSymbol);
   
   bool baseOrderOpened = false;
   bool currentOrderOpened = false;
   
   if(baseOrderType == ORDER_TYPE_BUY)
      baseOrderOpened = trade.Buy(lotBase, BaseSymbol);
   else
      baseOrderOpened = trade.Sell(lotBase, BaseSymbol);
   
   if(currentOrderType == ORDER_TYPE_BUY)
      currentOrderOpened = trade.Buy(lotCurrent, currentSymbol);
   else
      currentOrderOpened = trade.Sell(lotCurrent, currentSymbol);
   
   if(baseOrderOpened && currentOrderOpened)
   {
      Print("Opened pair trade: ", 
            OrderTypeToString(baseOrderType), " ", BaseSymbol, " and ", 
            OrderTypeToString(currentOrderType), " ", currentSymbol);
   }
   else
   {
      Print("Failed to open pair trade. Error: ", GetLastError());
      // 片方のオーダーのみ開いた場合、それをクローズ
      if(baseOrderOpened)
         trade.PositionClose(BaseSymbol);
      if(currentOrderOpened)
         trade.PositionClose(currentSymbol);
   }
}

//+------------------------------------------------------------------+
//| オーダータイプを文字列に変換                                     |
//+------------------------------------------------------------------+
string OrderTypeToString(ENUM_ORDER_TYPE orderType)
{
   switch(orderType)
   {
      case ORDER_TYPE_BUY: return "Buy";
      case ORDER_TYPE_SELL: return "Sell";
      default: return "Unknown";
   }
}

//+------------------------------------------------------------------+
//| Check if there are any open positions for our pair               |
//+------------------------------------------------------------------+
bool HasOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string positionSymbol = PositionGetString(POSITION_SYMBOL);
         if(StringFind(positionSymbol, BaseSymbol) != -1 || StringFind(positionSymbol, currentSymbol) != -1)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on free margin and exposure             |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double exposureAmount = freeMargin * (Exposure / 100.0);
   
   double symbolPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   
   double lotSize = exposureAmount / (symbolPrice * tickValue / tickSize);
   
   // Adjust lot size within allowed range and step
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMax(MathMin(lotSize, maxLot), minLot);
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Close all open positions                                         |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string positionSymbol = PositionGetString(POSITION_SYMBOL);
         if(StringFind(positionSymbol, BaseSymbol) != -1 || StringFind(positionSymbol, currentSymbol) != -1)
         {
            trade.PositionClose(PositionGetTicket(i));
         }
      }
   }
}
