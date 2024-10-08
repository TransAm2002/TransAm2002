//+------------------------------------------------------------------+
//| RUT_SPX.mq5                                                      |
//| Expert Advisor for S&P500 and Russell 2000                       |
//| by [Your Name]                                                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

CTrade Trade;

//--- input parameters
input double   risk_per_trade = 0.1;         // Risk per trade as a percentage of account balance
input double   fixed_lot_size = 0.1;         // Fixed lot size for testing purposes
input bool     use_fixed_lot_size = true;    // Whether to use fixed lot size or dynamic lot size
input int      max_positions = 4;            // Maximum number of open positions
input int      entry_threshold = 2;          // Entry threshold for price difference
input double   exit_threshold = 0.5;         // Exit threshold for price difference
input int      period = 100;                 // Period for regression and correlation
input int      volatility_period = 100;      // Period for volatility calculation
input double   volatility_multiplier = 2.0;  // Multiplier for volatility threshold
input long     magic_number = 123456;        // Magic number for the EA
input bool     debug_mode = true;            // Enable or disable debug mode
input ENUM_TIMEFRAMES TimeFrame = PERIOD_H4; // Timeframe for analysis
input string   SymbolInput_A = "US500Cash";  // Symbol A (e.g., US500Cash)
input string   SymbolInput_B = "US2000Cash"; // Symbol B (e.g., US2000Cash)
input bool     forceCloseOn = false;         // Enable force close feature
input int      forceCloseDays = 14;          // Days after which to force close positions

//--- global variables
datetime two_weeks;
double spx_prices[];
double rut_prices[];
double price_diffs[];
double volatility;
string Symbol_A;
string Symbol_B;

//--- trade objects
MqlTradeRequest trade_request;
MqlTradeResult trade_result;
MqlTradeTransaction transaction;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- initialization
    ArraySetAsSeries(spx_prices, true);
    ArraySetAsSeries(rut_prices, true);
    ArraySetAsSeries(price_diffs, true);
    
    two_weeks = forceCloseDays * 24 * 60 * 60; // forceCloseDays in seconds
    
    //--- print initialization message
    if(debug_mode) Print("RUT_SPX EA Initialized");
    
    Print("Selected TimeFrame: ", EnumToString(TimeFrame));
    
    //--- set symbols based on chart
    string chart_symbol = ChartSymbol(ChartID());
    if(chart_symbol == SymbolInput_A)
    {
        Symbol_A = SymbolInput_A;
        Symbol_B = SymbolInput_B;
    }
    else if(chart_symbol == SymbolInput_B)
    {
        Symbol_A = SymbolInput_B;
        Symbol_B = SymbolInput_A;
    }
    else
    {
        Print("チャートのシンボルが ", SymbolInput_A, " または ", SymbolInput_B, " ではありません。");
        return(INIT_FAILED);
    }
    
    Print("Symbol_A: ", Symbol_A);
    Print("Symbol_B: ", Symbol_B);
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- update prices
    if(!UpdatePrices())
    {
        Print("Failed to update prices. Skipping this tick.");
        return;
    }
    
    //--- calculate volatility
    if(ArraySize(price_diffs) >= volatility_period)
        volatility = CalculateVolatility(price_diffs, volatility_period);
    
    //--- perform regression and correlation calculations
    double regression_coefficient = 0.0;
    double correlation_coefficient = 0.0;
    if(ArraySize(spx_prices) >= period && ArraySize(rut_prices) >= period)
    {
        regression_coefficient = RegressionCoefficient(spx_prices, rut_prices, period);
        correlation_coefficient = CorrelationCoefficient(spx_prices, rut_prices, period);
        
        //--- entry logic based on price difference and volatility
        double upper_threshold = entry_threshold + volatility * volatility_multiplier;
        double lower_threshold = -entry_threshold - volatility * volatility_multiplier;
        
        if(price_diffs[0] > upper_threshold)
        {
            // Check current position count before opening new positions
            if(CountOpenPositions() < max_positions)
            {
                //--- calculate lot size for entry
                double stop_loss_pips = upper_threshold - lower_threshold;
                double calculated_lot_size = CalculatePositionSize(stop_loss_pips);
                
                //--- entry logic for long position on Symbol_A and short position on Symbol_B
                EnterLong(Symbol_A, calculated_lot_size);
                EnterShort(Symbol_B, calculated_lot_size);
            }
        }
        else if(price_diffs[0] < lower_threshold)
        {
            // Check current position count before opening new positions
            if(CountOpenPositions() < max_positions)
            {
                //--- calculate lot size for entry
                double stop_loss_pips = lower_threshold - upper_threshold;
                double calculated_lot_size = CalculatePositionSize(stop_loss_pips);
                
                //--- entry logic for short position on Symbol_A and long position on Symbol_B
                EnterShort(Symbol_A, calculated_lot_size);
                EnterLong(Symbol_B, calculated_lot_size);
            }
        }
        
        //--- exit logic based on price difference and volatility
        double exit_upper_threshold = exit_threshold + volatility * volatility_multiplier;
        double exit_lower_threshold = -exit_threshold - volatility * volatility_multiplier;
        
        if(price_diffs[0] < exit_upper_threshold && price_diffs[0] > exit_lower_threshold)
        {
            //--- exit logic for all positions
            ExitAllPositions();
        }
    }
    
    //--- check and close positions older than forceCloseDays
    CloseOldPositions();
    
    //--- check account equity to stop trading if loss exceeds 50%
    CheckAccountEquity();
}

//+------------------------------------------------------------------+
//| Custom function to update prices                                 |
//+------------------------------------------------------------------+
bool UpdatePrices()
{
    //--- update prices arrays
    double spx_price = iClose(Symbol_A, TimeFrame, 0);
    double rut_price = iClose(Symbol_B, TimeFrame, 0);
    
    if(spx_price == 0 || rut_price == 0)
    {
        Print("Failed to get prices for ", Symbol_A, " or ", Symbol_B);
        return false;
    }
    
    ArrayResize(spx_prices, ArraySize(spx_prices) + 1);
    ArrayResize(rut_prices, ArraySize(rut_prices) + 1);
    ArrayResize(price_diffs, ArraySize(price_diffs) + 1);
    spx_prices[0] = spx_price;
    rut_prices[0] = rut_price;
    price_diffs[0] = spx_price - rut_price;
    
    //--- limit array size
    if(ArraySize(spx_prices) > period) ArrayRemove(spx_prices, period);
    if(ArraySize(rut_prices) > period) ArrayRemove(rut_prices, period);
    if(ArraySize(price_diffs) > period) ArrayRemove(price_diffs, period);
    
    return true;
}

//+------------------------------------------------------------------+
//| Custom function to count the number of open positions            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Custom function to calculate volatility                          |
//+------------------------------------------------------------------+
double CalculateVolatility(double &local_price_diffs[], int local_period)
{
    double sum = 0.0;
    double mean = 0.0;
    double variance = 0.0;
    for(int i = 0; i < local_period; i++) sum += local_price_diffs[i];
    mean = sum / local_period;
    for(int i = 0; i < local_period; i++) variance += MathPow(local_price_diffs[i] - mean, 2);
    variance /= local_period;
    return MathSqrt(variance);
}

//+------------------------------------------------------------------+
//| Custom function to calculate regression coefficient              |
//+------------------------------------------------------------------+
double RegressionCoefficient(double &x[], double &y[], int local_period)
{
    double sumX = 0.0;
    double sumY = 0.0;
    double sumXY = 0.0;
    double sumX2 = 0.0;
    double n = local_period;
    for(int i = 0; i < local_period; i++)
    {
        sumX += x[i];
        sumY += y[i];
        sumXY += x[i] * y[i];
        sumX2 += x[i] * x[i];
    }
    double numerator = n * sumXY - sumX * sumY;
    double denominator = n * sumX2 - sumX * sumX;
    if(denominator != 0) return numerator / denominator;
    return 0.0;
}

//+------------------------------------------------------------------+
//| Custom function to calculate correlation coefficient             |
//+------------------------------------------------------------------+
double CorrelationCoefficient(double &x[], double &y[], int local_period)
{
    double sumX = 0.0;
    double sumY = 0.0;
    double sumXY = 0.0;
    double sumX2 = 0.0;
    double sumY2 = 0.0;
    double n = local_period;
    for(int i = 0; i < local_period; i++)
    {
        sumX += x[i];
        sumY += y[i];
        sumXY += x[i] * y[i];
        sumX2 += x[i] * x[i];
        sumY2 += y[i] * y[i];
    }
    double numerator = n * sumXY - sumX * sumY;
    double denominator = MathSqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY));
    if(denominator != 0) return numerator / denominator;
    return 0.0;
}

//+------------------------------------------------------------------+
//| Custom function to calculate position size                       |
//+------------------------------------------------------------------+
double CalculatePositionSize(double stop_loss_pips)
{
    double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double lot_size = 0.0;
    if(use_fixed_lot_size)
    {
        lot_size = fixed_lot_size;
    }
    else
    {
        double risk_amount = account_balance * risk_per_trade;
        double risk_per_pip = stop_loss_pips * SymbolInfoDouble(Symbol_A, SYMBOL_MARGIN_INITIAL);
        lot_size = risk_amount / risk_per_pip;
        
        //--- adjust lot size to comply with symbol constraints
        double min_lot = SymbolInfoDouble(Symbol_A, SYMBOL_VOLUME_MIN);
        double max_lot = SymbolInfoDouble(Symbol_A, SYMBOL_VOLUME_MAX);
        double lot_step = SymbolInfoDouble(Symbol_A, SYMBOL_VOLUME_STEP);
        lot_size = MathMax(min_lot, MathMin(lot_size, max_lot));
        lot_size = MathFloor(lot_size / lot_step) * lot_step;
    }
    return lot_size;
}

//+------------------------------------------------------------------+
//| Custom function to send a buy order                              |
//+------------------------------------------------------------------+
void EnterLong(string symbol, double lot_size)
{
    if(debug_mode) Print("Entering long position for ", symbol, " with lot size ", lot_size);
    trade_request.action = TRADE_ACTION_DEAL;
    trade_request.symbol = symbol;
    trade_request.volume = lot_size;
    trade_request.type = ORDER_TYPE_BUY;
    trade_request.type_filling = ORDER_FILLING_IOC;
    trade_request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    trade_request.sl = 0;
    trade_request.tp = 0;
    trade_request.deviation = 10;
    trade_request.magic = magic_number;
    trade_request.comment = "RUT_SPX Long Entry";
    if(!OrderSend(trade_request, trade_result))
    {
        if(debug_mode) Print("Error opening long position: ", trade_result.retcode);
    }
}

//+------------------------------------------------------------------+
//| Custom function to send a sell order                             |
//+------------------------------------------------------------------+
void EnterShort(string symbol, double lot_size)
{
    if(debug_mode) Print("Entering short position for ", symbol, " with lot size ", lot_size);
    trade_request.action = TRADE_ACTION_DEAL;
    trade_request.symbol = symbol;
    trade_request.volume = lot_size;
    trade_request.type = ORDER_TYPE_SELL;
    trade_request.type_filling = ORDER_FILLING_IOC;
    trade_request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
    trade_request.sl = 0;
    trade_request.tp = 0;
    trade_request.deviation = 10;
    trade_request.magic = magic_number;
    trade_request.comment = "RUT_SPX Short Entry";
    if(!OrderSend(trade_request, trade_result))
    {
        if(debug_mode) Print("Error opening short position: ", trade_result.retcode);
    }
}

//+------------------------------------------------------------------+
//| Custom function to close all positions                           |
//+------------------------------------------------------------------+
void ExitAllPositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!Trade.PositionClose(ticket))
        {
            if(debug_mode) Print("Error closing position with ticket ", ticket);
        }
    }
}

//+------------------------------------------------------------------+
//| Custom function to close positions older than forceCloseDays     |
//+------------------------------------------------------------------+
void CloseOldPositions()
{
    // Check if forceClose is enabled
    if(!forceCloseOn) return;
    datetime current_time = TimeCurrent();
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetInteger(POSITION_TIME) + two_weeks <= current_time)
        {
            ulong ticket = PositionGetTicket(i);
            if(!Trade.PositionClose(ticket))
            {
                if(debug_mode) Print("Error closing old position with ticket ", ticket);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Custom function to check account equity and stop trading if loss |
//+------------------------------------------------------------------+
void CheckAccountEquity()
{
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(equity < balance * 0.5)
    {
        ExitAllPositions();
        ExpertRemove();
    }
}

//+------------------------------------------------------------------+
//| Custom function for testing and optimization                     |
//+------------------------------------------------------------------+
double OnTester()
{
    // Custom optimization criteria can be implemented here
    return 0.0;
}