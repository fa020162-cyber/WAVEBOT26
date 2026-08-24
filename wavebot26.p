
import os, time, math, requests
from binance.client import Client
from binance.exceptions import BinanceAPIException
import pandas as pd
import numpy as np

# === إعداداتك ===
API_KEY = os.getenv("BINANCE_API_KEY")
API_SECRET = os.getenv("BINANCE_SECRET")
CAPITAL_USDT = 26
LEVERAGE_ALL_IN = True  # دخول بكل المحفظة
TAKE_PROFIT = 0.04  # 4%
STOP_LOSS = 0.02    # 2%
TIMEFRAME = "5m"
TOP_N = 20

# عملات التوب - نجيبها تلقائيا من بينانس حسب الفوليوم
def get_top_coins(client, n=20):
    tickers = client.get_ticker()
    # فلتر USDT فقط وترتيب بالفوليوم
    usdt = [t for t in tickers if t['symbol'].endswith('USDT') and not t['symbol'].endswith('BUSD')]
    sorted_t = sorted(usdt, key=lambda x: float(x['quoteVolume']), reverse=True)
    # استبعد العملات المستقرة
    exclude = ['USDCUSDT','FDUSDUSDT','TUSDUSDT','USDPUSDT','EURUSDT']
    symbols = [t['symbol'] for t in sorted_t if t['symbol'] not in exclude][:n]
    return symbols

def get_klines(client, symbol, interval="5m", limit=200):
    klines = client.get_klines(symbol=symbol, interval=interval, limit=limit)
    df = pd.DataFrame(klines, columns=['time','open','high','low','close','vol','close_time','qvol','trades','taker_base','taker_quote','ignore'])
    df['close'] = df['close'].astype(float)
    df['high'] = df['high'].astype(float)
    df['low'] = df['low'].astype(float)
    return df

# كشف موجة إليوت مبسط: موجة 3 و موجة C
def detect_wave_3(df):
    # موجة 3: بعد تصحيح موجة 2، كسر قمة موجة 1 مع RSI قوي وحجم عالي
    # تبسيط: 3 قيعان صاعدة + اختراق أعلى قمة 20 شمعة مع مومنتوم
    if len(df) < 50: return False
    closes = df['close'].values
    # موجة 1: صعود
    # موجة 2: نزول لا يكسر بداية موجة 1
    # موجة 3: اختراق قمة موجة 1
    recent_high = np.max(closes[-30:-5])
    recent_low = np.min(closes[-20:-5])
    curr = closes[-1]
    prev = closes[-2]
    # شروط موجة 3: السعر فوق قمة 30 شمعة، والشمعة السابقة كانت تصحيح
    if curr > recent_high * 1.002 and prev < curr and (curr - recent_low)/recent_low > 0.015:
        # تأكيد مومنتوم: 3 شموع خضراء متتالية
        if closes[-1] > closes[-2] > closes[-3]:
            return True
    return False

def detect_wave_C(df):
    # موجة C: نهاية التصحيح، ارتداد من قاع
    # تبسيط: نزول قوي ثم تشكيل قاع مزدوج / شمعة انعكاسية + صعود
    if len(df) < 50: return False
    closes = df['close'].values
    lows = df['low'].values
    recent_low = np.min(lows[-30:-5])
    curr = closes[-1]
    # ارتداد من قاع: السعر كان تحت ثم رجع فوق القاع بـ 1%
    if lows[-2] <= recent_low*1.001 and curr > lows[-2]*1.015 and curr > closes[-2]:
        if closes[-1] > closes[-2] and closes[-2] > closes[-3]*0.998: # بداية انعكاس
            return True
    return False

def trade_all_in(client, symbol):
    try:
        balance = client.get_asset_balance(asset='USDT')
        usdt = float(balance['free'])
        if usdt < 5:
            print(f"رصيد غير كافي: {usdt}")
            return None
        # كل المحفظة
        price = float(client.get_symbol_ticker(symbol=symbol)['price'])
        # حساب الكمية
        info = client.get_symbol_info(symbol)
        lot_filter = next(f for f in info['filters'] if f['filterType']=='LOT_SIZE')
        step = float(lot_filter['stepSize'])
        qty = usdt / price
        qty = math.floor(qty / step) * step
        # تنفيذ شراء MARKET
        order = client.order_market_buy(symbol=symbol, quantity=qty)
        print(f"✅ دخول ALL-IN {symbol} @ {price} كمية {qty} - موجة مكتشفة")
        # حدد TP/SL
        tp_price = price * (1 + TAKE_PROFIT)
        sl_price = price * (1 - STOP_LOSS)
        # أوامر OCO للبيع
        try:
            # بيع TP/SL
            client.create_oco_order(symbol=symbol, side='SELL', quantity=qty,
                price=str(round(tp_price,4)), stopPrice=str(round(sl_price,4)),
                stopLimitPrice=str(round(sl_price*0.998,4)), stopLimitTimeInForce='GTC')
            print(f"   TP {tp_price:.4f} / SL {sl_price:.4f} تم وضعه")
        except Exception as e:
            print(f"تحذير TP/SL: {e}")
        return order
    except BinanceAPIException as e:
        print(f"خطأ تداول {symbol}: {e}")
        return None

def main():
    print("🚀 Wavebot26 بدأ - رأس مال 26$ - موجة 3 + C - فريم 5m")
    client = Client(API_KEY, API_SECRET)
    # تأكد من الاتصال
    try:
        client.get_account()
        print("✅ API متصل ومفعل")
    except Exception as e:
        print(f"❌ فشل الاتصال: {e}")
        return

    in_position = False
    while True:
        try:
            if in_position:
                # انتظر البيع
                time.sleep(30)
                bal = float(client.get_asset_balance(asset='USDT')['free'])
                if bal > 5:
                    in_position = False
                    print("🔄 رجعنا USDT - نبحث عن صفقة جديدة")
                continue

            symbols = get_top_coins(client, TOP_N)
            print(f"فحص {len(symbols)} عملة...")
            for sym in symbols:
                try:
                    df = get_klines(client, sym, TIMEFRAME, 200)
                    w3 = detect_wave_3(df)
                    wc = detect_wave_C(df)
                    if w3 or wc:
                        typ = "موجة 3" if w3 else "موجة C"
                        print(f"🎯 {sym} -> {typ} مكتشفة!")
                        trade_all_in(client, sym)
                        in_position = True
                        break
                    time.sleep(0.3)
                except Exception as e:
                    continue
            if not in_position:
                print("لا يوجد موجة حالياً - انتظار دقيقة...")
                time.sleep(60)
        except Exception as e:
            print(f"خطأ عام: {e}")
            time.sleep(10)

if __name__ == "__main__":
    main()
