def backtest(symbol, options:)
  # ensure output folder exists even if main block didn't run
  Dir.mkdir(RESULTS_DIR) unless Dir.exist?(RESULTS_DIR)

  # cooldown should be per-symbol, not shared across symbols/configs
@last_sell_date = nil
@last_fcx_loss  = nil   

atr_stop   = options[:atr_stop]   || $atr_stop
atr_profit = options[:atr_profit] || $atr_profit
sma_filter = options[:sma_filter] || $sma_filter

file_path = data_csv_for(symbol)
raise "Missing file for #{symbol}: looked under #{DATA_DIR}" unless file_path && File.exist?(file_path)

hold_map = {
  1 => 10, # Monday entry: hold 2 days (Exit Wed)
  2 => 10, # Tuesday entry: hold 3 days (Exit Fri)
  3 => 10, # Wednesday entry: hold 1 day (Quick scalp)
  4 => 10, # Thursday entry: hold 1 day (Avoid weekend)
  5 => 10  # Friday entry: hold 3 days (Monday/Tuesday Exit)
}


base = symbol.split("_").first

#if ["BTC", "BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA"].include?(base)
 # hold_map = {
  #  0 => 10, # Sunday
   # 1 => 10,
   # 2 => 10,
   # 3 => 10,
   # 4 => 10,
   # 5 => 10,
   # 6 => 10 # Saturday
 # }
#end

if ["BTC", "BTCUSD", "ETHUSD", "ETHA"].include?(base)
hold_map = {
  0  => 10,
  1  => 10,
  2  => 10,
  3  => 10,
  4  => 10,
  5  => 10,
  6  => 10,
  7  => 10,
  8  => 10,
  9  => 10,
  10 => 10,
  11 => 10,
  12 => 10,
  13 => 10,
  14 => 10,
  15 => 10,
  16 => 10,
  17 => 10,
  18 => 10,
  19 => 10,
  20 => 10,
  21 => 10,
  22 => 10,
  23 => 10
}
end



  sep = detect_sep(file_path)
  rows = CSV.read(file_path,
                headers: true,
                col_sep: sep,
                header_converters: ->(h) { h&.strip&.downcase&.gsub(/\s+/, '') },
                converters: ->(f) { f&.strip })
  bench = load_benchmark("QQQ_GoogleFinance_AutoUpToDate")
  closes = rows['close'].map(&:to_f)
  date_col = rows.headers.find { |h| h =~ /date|time/i }
  dates = rows[date_col]
  atr_vals = calculate_atr(rows, ATR_PERIOD)
  opens  = rows['open']  ? rows['open'].map(&:to_f)  : Array.new(closes.size, nil)

# 60-day drawdown series used by policy
dd60_series = []
closes.each_with_index do |_, j|
  if j >= 59
    high60 = closes[(j-59)..j].max
    dd60_series << ((closes[j] - high60) / high60.to_f)  # ≤ 0
  else
    dd60_series << nil
  end
end

# --- OPEN PRICES (needed for gap calculations in the policy) ---
opens  = rows['open'] ? rows['open'].map(&:to_f) : Array.new(closes.size, nil)

# --- 60d drawdown series for policy (dd60 = close / 60d_high - 1) ---
dd60_series = []
closes.each_with_index do |c, idx|
  if idx >= 59
    win_max = closes[(idx-59)..idx].max
    dd60_series << (win_max && win_max > 0 ? (c / win_max - 1.0) : nil)
  else
    dd60_series << nil
  end
end

# === VOLUME FILTER CALCULATION ===
volumes = rows['volume'] ? rows['volume'].map(&:to_f) : []
avg_volume = []
vol_window = 20  # lookback window for avg volume

if volumes.any?
  volumes.each_with_index do |_, j|
    if j >= vol_window
      avg_volume << volumes[(j - vol_window)...j].sum / vol_window.to_f
    else
      avg_volume << nil
    end
  end
else
  avg_volume = Array.new(closes.size, nil)
end

  trades, signals = [], []
  position = nil

 rsi2_vals = calculate_rsi(closes, rsi2_cfg[:period])
 rsi3_vals = calculate_rsi(closes, rsi3_cfg[:period])
 rsi2_at = rsi2_vals.to_h
 rsi3_at = rsi3_vals.to_h
# === SMA100 Calculation ===
sma100 = []
closes.each_with_index do |_, j|
  if j >= 99
    sma100 << closes[(j-99)..j].sum / 100.0
  else
    sma100 << nil
  end
end

# === SMA200 Calculation ===
sma200 = []
closes.each_with_index do |_, j|
  if j >= 199
    sma200 << closes[(j-199)..j].sum / 200.0
  else
    sma200 << nil
  end
end

# === PRELOAD MULTI-SIGNAL FILE ONCE ===
multi_signal_path = File.join(RESULTS_DIR, "#{symbol}_multi_signals.csv")

# Always rewrite the multi-signal file fresh (skip in FAST_SWEEP)
write_csv_unless_fast(multi_signal_path, %w[date symbol signal close], mode: "w")
global_signal_path = File.join(RESULTS_DIR, "hybrid_v3_all_signals.csv")

existing_rows = []  # start clean each run

bench = load_benchmark("QQQ_GoogleFinance_AutoUpToDate")
bench_index = 0

$vxx = load_benchmark("VXX_GoogleFinance_AutoUpToDate")
vxx_index = 0

$vixy = load_benchmark("VIXY_GoogleFinance_AutoUpToDate")
vixy_closes = $vixy[:close] if $vixy

unless vixy_closes
  puts "[WARNING] VIXY data missing — volatility filter disabled"
end

vixy_block_days = 0  


highs = rows['high'].map(&:to_f)
closes.each_with_index do |close, i|

  date = dates[i]   
  high = highs[i]
=begin
if position

entry_date   = Date.parse(position[:entry_date].to_s)
current_date = Date.parse(date.to_s)
entry_wday   = entry_date.wday
current_wday = current_date.wday
 hold_days = (current_date - entry_date).to_i


  if entry_wday == 2 && current_wday == 5
    puts "[TUE→FRI EXIT] #{symbol} | Held: #{hold_days}d"

    exit_price = (opens && (i + 1) < opens.length && opens[i + 1]) ? opens[i + 1].to_f : close.to_f

    trades << {
      symbol: symbol,
      entry_date: position[:entry_date],
      exit_date: date,
      entry: position[:entry],
      exit: exit_price,
      pct_return: ((exit_price - position[:entry]) / position[:entry]) * 100
    }

    position = nil
    next
  end
=end

if position

  entry_date   = Date.parse(position[:entry_date].to_s)
  current_date = Date.parse(date.to_s)
  entry_wday   = entry_date.wday
  hold_days    = (current_date - entry_date).to_i
  pct_return = ((close.to_f - position[:entry].to_f) / position[:entry].to_f) * 100.0


# ===============================
# TAKE-PROFIT %
# ===============================

=begin
base = symbol.split("_").first

take_profit_pct = TAKE_PROFIT_MAP[base] || 5.0
target_price = position[:entry].to_f * (1 + take_profit_pct / 100.0)

if high >= target_price
  trades << {
    symbol: symbol,
    entry_date: position[:entry_date],
    exit_date: date,
    entry: position[:entry],
    exit: target_price,
    pct_return: take_profit_pct
  }

  position = nil
  next
end
=end
# ===============================
# TIME-STOP 
# ===============================
if hold_days >= 7 && pct_return < 0
 # puts "⏳ [TIME-STOP] #{symbol} | Held: #{hold_days}d | P/L: #{pct_return.round(2)}%"

  exit_price =
    if opens && (i + 1) < opens.length && opens[i + 1]
      opens[i + 1].to_f
    else
      close.to_f
    end

  trades << {
    symbol: symbol,
    entry_date: position[:entry_date],
    exit_date: date,
    entry: position[:entry],
    exit: exit_price,
    pct_return: ((exit_price - position[:entry]) / position[:entry]) * 100
  }

  position = nil
  next
end

  # Get how long we SHOULD hold based on entry day
  target_hold = hold_map[entry_wday]

  if target_hold && hold_days >= target_hold
   # puts "[TIME EXIT #{entry_wday}→#{target_hold}d] #{symbol} | Held: #{hold_days}d"

    exit_price =
      if opens && (i + 1) < opens.length && opens[i + 1]
        opens[i + 1].to_f
      else
        close.to_f
      end

    trades << {
      symbol: symbol,
      entry_date: position[:entry_date],
      exit_date: date,
      entry: position[:entry],
      exit: exit_price,
      pct_return: ((exit_price - position[:entry]) / position[:entry]) * 100
    }

    position = nil
    next
  end

  entry_date = Date.parse(position[:entry_date].to_s)
  current_date = Date.parse(date.to_s)
=begin
  if hold_days >= 6
    puts "[TIME_EXIT] #{symbol} | Held: #{hold_days}d"

    exit_price = (opens && (i + 1) < opens.length && opens[i + 1]) ? opens[i + 1].to_f : close.to_f

    trades << {
      symbol: symbol,
      entry_date: position[:entry_date],
      exit_date: date,
      entry: position[:entry],
      exit: exit_price,
      pct_return: ((exit_price - position[:entry]) / position[:entry]) * 100
    }

    position = nil
    next
  end
=end
end

# --- NEW SELECTIVE ENFORCEMENT ---
if vixy_block_days > 0
  vixy_block_days -= 1
  
  # 1. Define the ticker being checked right now
  ticker_name = symbol.split("_").first
  
  # 2. Define the 'Safe Haven' group
  elites = Object.new.tap { |o| def o.include?(*); true; end }
 # elites = ["SMCI", "SMR", "NVDA", "VRT", "LRCX", "ARM", "VST", 
 # "CCJ", "GEV", "CEG", "DELL", "AVGO", "PANW", "CYBR", "AMD", "MOD", 
 # "FIX", "BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA", "MU", "QCOM", "TSM", "MRVL", "MA", "CAT", "DE",
 # "GS", "MS", "JPM", "KKR", "META", "LLY", "TSLA", "COIN", "BLK", "GOOGL", "NVT"
#]
  
  # 3. If it's NOT an elite, apply the block
  unless elites.include?(ticker_name)
    next # Standard stocks (MU, TSM, AMD) stay in the bunker
  end
  # If it IS an elite, the code continues and checks for a BUY signal!
end

next if i < [rsi2_cfg[:period], rsi3_cfg[:period], breakout_entry].max

#puts "[VIXY RAW] #{symbol} #{date} vixy=#{vixy_closes[i]}" if vixy_closes && !$FAST_SWEEP

  # === VIXY VOLATILITY SPIKE FILTER ===
vixy_block = false

# ==========================================================
# PART A: DAILY PANIC DETECTION 
# ==========================================================
if vixy_closes && i >= 5
  log_today = Math.log(vixy_closes[i].to_f)
  
  # 1. Main Trigger: 5-Day Velocity (~8% spike)
  v5 = log_today - Math.log(vixy_closes[i - 5].to_f)
  if v5 > 0.025
    vixy_block_days = 15
    puts "[VIXY PANIC] #{date} | Blocked for 15 days" unless $FAST_SWEEP
  end

  # 2. Fast Shock: 3-Day Velocity (~6% spike)
  v3 = log_today - Math.log(vixy_closes[i - 3].to_f)
  if v3 > 0.03
    vixy_block_days = 12
    puts "[VIXY FAST PANIC] #{date} | Blocked for 12 days" unless $FAST_SWEEP
  end
end

# ==========================================================
# PART B: SYMBOL ENFORCEMENT (Run this inside your Symbol loop)
# ==========================================================
ticker_name = symbol.split("_").first
#master_elites = ["SMCI", "SMR", "NVDA", "VRT", "LRCX", "ARM", "VST", 
#"CCJ", "GEV", "CEG", "DELL", "AVGO", "PANW", "CYBR", "AMD", "MOD", "FIX", 
#"BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA", "MU", "QCOM", "TSM", "MRVL", "MA", "CAT", "DE",
#"GS", "MS", "JPM", "KKR", "META", "LLY", "TSLA", "COIN", "BLK", "GOOGL", "NVT"]
master_elites = Object.new.tap { |o| def o.include?(*); true; end }
is_elite = true
#is_elite = master_elites.include?(ticker_name)

# 1. The Bunker Rule: Only Elites trade during Panic
if vixy_block_days > 0 && !is_elite
  next 
end

# 2. The Knife Rule: Only Elites buy 3-day consecutive drops
if i >= 3 && !is_elite
  if closes[i] < closes[i-1] && closes[i-1] < closes[i-2] && rsi2_at[i] > 20
    next
  end
end
# === Date filter: skip rows before desired start date ===
#start_cutoff = Date.new(2017, 1, 1)
#d = (Date.parse(dates[i]) rescue nil)
#next if d && d < start_cutoff

vxx_value = nil

if $vxx && $vxx[:date] && $vxx[:close]
  vxx_index += 1 while vxx_index < $vxx[:date].size - 1 &&
                          $vxx[:date][vxx_index] < date

  if $vxx[:date][vxx_index] == date
    vxx_value = $vxx[:close][vxx_index].to_f
  end
end

# per-bar ATR (may be nil)
atr = atr_vals[i]
atr = (atr && atr.to_f > 0.0) ? atr.to_f : nil

# Is the market regime healthy (QQQ > rising 200dma)?
current_date = Date.parse(date) rescue nil

while bench && bench_index < bench[:dates].size &&
      bench[:dates][bench_index] &&
      bench[:dates][bench_index] <= current_date
  bench_index += 1
end

bi = bench_index - 1
reg_ok = regime_ok_fast(bi, bench)

# Windowing for fast sweep (skip rows outside the requested span)
if options[:from] || options[:to]
  d = (Date.parse(date) rescue nil)
  next if options[:from] && d && d < options[:from]
  next if options[:to]   && d && d > options[:to]
end

signal = "HOLD"

hold_reasons = []

hold_reasons << "Trailing stop not hit"
hold_reasons << "ATR stop not hit"
hold_reasons << "Breakout exit not triggered"
hold_reasons << "SMA filter OK (stay in trade)" if defined?(sma_ok) && sma_ok
hold_reasons << "RSI not overheated" if defined?(rsi3) && rsi3 && rsi3 < 90

reason_text = hold_reasons.uniq.join(", ")

msg = "HOLD #{symbol} #{date} @ #{close} → #{reason_text}"

# === VOLUME FILTER RULE ===
#if avg_volume[i] && volumes[i] && volumes[i] < avg_volume[i] * 0.5
  # skip low-volume day (<50% of 20-day average)
 # next
#end

# === VOLUME FILTER RULE (GOOGL-only) ===
#$vol_cfg = {
#  "GOOGL_GoogleFinance_AutoUpToDate" => { min: 1.10, max: 3.50 },
 # "FCX_GoogleFinance_AutoUpToDate"   => { min: 1.30, max: 3.0 },

 # "NVDA_GoogleFinance_AutoUpToDate"  => { min: 1.20, max: 2.50 },
#}

# Optional: simple FCX volume sanity (very gentle, won’t block others)
if symbol.to_s.include?("FCX") && volumes.any? && avg_volume[i] && volumes[i]
  relv = volumes[i] / avg_volume[i].to_f
  # Example trims only the most illiquid blips; comment out while tuning if desired
  # next if relv < 0.6
end

# === VOLUME FILTER RULE (per-symbol from $vol_cfg) ===
$vol_cfg ||= {}  # ensure it's at least an empty Hash

cfg = nil
begin
  # Find a matching per-symbol config by substring
  cfg = $vol_cfg.is_a?(Hash) ? $vol_cfg.find { |tag, _| symbol.to_s.include?(tag.to_s) }&.last : nil
rescue
  cfg = nil
end

if cfg
  min_rv = cfg[:min]
  max_rv = cfg[:max]

  if avg_volume[i] && volumes[i]
    relv = volumes[i] / avg_volume[i].to_f
    next if min_rv && relv < min_rv
    next if max_rv && relv > max_rv
  else
    # If you prefer NOT to skip when volume data is missing, comment the next line.
    # next
  end
end

  # RSI2
  rsi2 = rsi2_vals.find { |idx, _| idx == i }&.last
  rsi2_signal = if rsi2 && rsi2 <= rsi2_cfg[:oversold]
                 "BUY"
               elsif rsi2 && rsi2 >= rsi2_cfg[:overbought]
                 "SELL"
               else
                 "HOLD"
               end

  # RSI3
  rsi3 = rsi3_vals.find { |idx, _| idx == i }&.last
  rsi3_signal = if rsi3 && rsi3 <= rsi3_cfg[:oversold]
                 "BUY"
               elsif rsi3 && rsi3 >= rsi3_cfg[:overbought]
                 "SELL"
               else
                 "HOLD"
               end
  # Breakout
  breakout_signal = "HOLD"

  if i >= breakout_entry && i >= breakout_exit
    high_n = closes[(i - breakout_entry)...i].max
    low_m  = closes[(i - breakout_exit)...i].min

    breakout_signal = "BUY"  if close > high_n
    breakout_signal = "SELL" if close < low_m
  end

  # Rule: RSI2 + RSI3 must agree, breakout must not contradict
  chosen_signal = "HOLD"
  if rsi2_signal == rsi3_signal && rsi2_signal != "HOLD"
    if (rsi2_signal == "BUY" && breakout_signal != "SELL") ||
       (rsi2_signal == "SELL" && breakout_signal != "BUY")
      chosen_signal = rsi2_signal
    end
  end

# Debug: show early signals before SMA filter blocks them
if Date.parse(date).year < 2005 && chosen_signal != "HOLD"
 # puts "[DEBUG] #{symbol} #{date} RSI2=#{rsi2&.round(2)} RSI3=#{rsi3&.round(2)} Breakout=#{breakout_signal} → #{chosen_signal}"
end

=begin
# --- MOMENTUM SIGNAL (MORE TRADES) ---
momentum_signal = "HOLD"

if i >= 10
  high_10 = closes[(i - 10)...i].max

  # easier breakout
  if close >= high_10 * 0.995
    momentum_signal = "BUY"
  end
end

# --- MERGE ---
if momentum_signal == "BUY" && chosen_signal != "SELL"
  chosen_signal = "BUY"
end
=end

# This variable must be tracked globally. 
# If any ticker in your list is currently 'in a trade', skip everything else.
# =============================================================
# === UNIFIED STRATEGY LOGIC 8.1  ===
# =============================================================

# --- STEP 1: MOMENTUM FILTER (Waterfall Protection) ---
if i >= 3
  ticker_name = symbol.split("_").first
  kings = Object.new.tap { |o| def o.include?(*); true; end }
 # kings = ["ARM", "SMCI", "DELL", "LRCX", "NVDA", "AVGO", "VST", "AMD", 
  #"MOD", "FIX", "BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA", "MU", "QCOM", "TSM", "MRVL", "MA", "CAT", "DE",
  #"GS", "MS", "JPM", "KKR", "META", "LLY", "TSLA", "COIN", "BLK", "GOOGL", "NVT"]
  
  # SURGICALS and VOLATILES must wait for a green day (Close > Prev Close).
  unless kings.include?(ticker_name)
    if closes[i] <= closes[i-1] # If today is red or flat, wait.
      next
    end
  end
end

exit_triggered = false
sell_signal = false # 
# --- STEP 2: POSITION MANAGEMENT (Exits) ---
if position
  entry_price = position[:entry].to_f
  pct_return = ((close.to_f - entry_price) / entry_price) * 100

  # 1. HARD FLOOR EXIT
 # if pct_return < -2.0
 #   exit_triggered = true
 #   exit_reason = "HARD_STOP_LOSS"
 # end

  # ... (Other exit logic like Time Stop or RSI) ...

  # IMPORTANT: This block closes the "if exit_triggered" logic
# === THE MASTER RELEASE (Add this at the bottom of Step 2) ===
# --- STEP 2: MASTER EXIT EXECUTION ---
  if exit_triggered || sell_signal
    if position
      # Reduce the global slot count
      $global_active_slots -= 1
      
      # Clear the ticker name so it can be bought again later
      ticker_name = symbol.split("_").first
      $active_tickers.delete(ticker_name) if $active_tickers
      
      # Safety: prevent negative numbers
      $global_active_slots = 0 if $global_active_slots < 0

      puts "🏁 [SLOT CLOSED] #{symbol} | Active: #{$global_active_slots}/3"
    end

    # 2. CLEAR THE DATA (last thing to do)
    position = nil 
  end
end # This ends the 'if position' block

# --- STEP 3: DYNAMIC TIERED BUYING ---
if chosen_signal == "BUY"

#puts "[SIGNAL DEBUG] #{symbol} #{date} " \
 #    "FINAL=#{chosen_signal} " \
  #   "BREAKOUT=#{breakout_signal} " \
   #  "RSI2=#{rsi2_signal} " \
    # "RSI3=#{rsi3_signal}"

base = symbol.to_s.split("_").first

momentum_settings = {
  "SMCI2" => {
    days: 9,
    threshold: 0.027,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 2.7
  },

    "MSTR1" => {
    days: 50,
    threshold: 0.01,
    mode: :strict,
    below_sma_mult: 0.1,
    red_days_mult: 3.1
  },

   "IBIT1" => {
    days: 50,
    threshold: 0.01,
    mode: :strict,
    below_sma_mult: 0.1,
    red_days_mult: 3.1
  },

   "ETHA1" => {
    days: 50,
    threshold: 0.01,
    mode: :strict,
    below_sma_mult: 0.1,
    red_days_mult: 3.1
  },

      "BTCUSD1" => {
    days: 30,
    threshold: 0.03,
    mode: :strict,
    below_sma_mult: 1.0,
    red_days_mult: 0.2
  },

    "ETHUSD1" => {
    days: 30,
    threshold: 0.03,
    mode: :strict,
    below_sma_mult: 1.0,
    red_days_mult: 0.2
  },

    "NVDA2" => {
    days: 75,
    threshold: 0.07,
    mode: :strict,
    below_sma_mult: 1.5,
    red_days_mult: 7.0
  },

    "VRT1" => {
    days: 60,
    threshold: 0.04,
    mode: :strict,
    below_sma_mult: 0.2,
    red_days_mult: 0.2
  },

    "DELL2" => {
    days: 45,
    threshold: -0.01,
    mode: :strict,
    below_sma_mult: 1.5,
    red_days_mult: 3.0
  },

    "VST2" => {
    days: 250,
    threshold: 0.40,
    mode: :strict,
    below_sma_mult: 0.2,
    red_days_mult: 1.5
  },

  "FIX2" => {
    days: 120,
    threshold: 0.02,
    mode: :strict,
    below_sma_mult: 0.2,
    red_days_mult: 0.5
  },

  "MA2" => {
    days: 12,
    threshold: 0.01,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 0.1
  },

  "CAT2" => {
    days: 20,
    threshold: 0.015,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 0.3
  },

    "META2" => {
    days: 150,
    threshold: 0.02,
    mode: :strict,
    below_sma_mult: 2.5,
    red_days_mult: 0.3
  },

    "LLY2" => {
    days: 15,
    threshold: 0.015,
    mode: :lenient,
    below_sma_mult: 0.5,
    red_days_mult: 0.5
  },


    "GS1" => {
    days: 18,
    threshold: 0.06,
    mode: :strict,
    below_sma_mult: 0.7,
    red_days_mult: 1.9
  },

      "MS1" => {
    days: 30,
    threshold: 0.015,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 1.3
  },

        "JPM1" => {
    days: 30,
    threshold: 0.015,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 1.3
  },

    "DE2" => {
    days: 20,
    threshold: 0.015,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 0.3
  },

    "AVGO2" => {
    days: 75,
    threshold: 0.01,       # Wait for a deeper, cleaner 5% drop
    mode: :strict,
    below_sma_mult: 0.20,  # Allocate heavier when trading at a discount below trend
    red_days_mult: 5.0 # Slightly lower multiplier to account for the larger base threshold
  },

    "1ANET" => {
    days: 75,
    threshold: 0.01,       # Wait for a deeper, cleaner 5% drop
    mode: :strict,
    below_sma_mult: 0.20,  # Allocate heavier when trading at a discount below trend
    red_days_mult: 5.0 # Slightly lower multiplier to account for the larger base threshold
  },

     "ADI1" => {
    days: 75,
    threshold: 0.01,       # Wait for a deeper, cleaner 5% drop
    mode: :strict,
    below_sma_mult: 0.20,  # Allocate heavier when trading at a discount below trend
    red_days_mult: 5.0 # Slightly lower multiplier to account for the larger base threshold
  },

    "QCOM" => {
    days: 75,
    threshold: 0.01,       # Wait for a deeper, cleaner 5% drop
    mode: :strict,
    below_sma_mult: 0.20,  # Allocate heavier when trading at a discount below trend
    red_days_mult: 5.0 # Slightly lower multiplier to account for the larger base threshold
  },

    "TXN2" => {
    days: 75,
    threshold: 0.01,       # Wait for a deeper, cleaner 5% drop
    mode: :strict,
    below_sma_mult: 0.20,  # Allocate heavier when trading at a discount below trend
    red_days_mult: 5.0 # Slightly lower multiplier to account for the larger base threshold
  },

    "MOD1" => {
    days: 15,
    threshold: 0.01,
    mode: :strict,
    below_sma_mult: 0.0,
    red_days_mult: 0.5
  },

    "MSFT2" => {
    days: 175,
    threshold: 0.10,
    mode: :strict,
    below_sma_mult: 2.0,
    red_days_mult: 0.5
  },

      "AAPL2" => {
    days: 100,
    threshold: 0.005,
    mode: :strict,
    below_sma_mult: 0.2,
    red_days_mult: 3.2
  },

    "1MCHP" => {
    days: 180,
    threshold: 0.10,
    mode: :strict,
    below_sma_mult: 1.0,
    red_days_mult: 2.0
  },


    "AMD2" => {
    days: 7,
    threshold: 0.04,
    mode: :strict,
    below_sma_mult: 1.0,
    red_days_mult: 7.0
  },

    "TSM2" => {
    days: 20,
    threshold: 0.03,
    mode: :strict,
    below_sma_mult: 0.8,
    red_days_mult: 1.5
  },

    "MRVL1" => {
    days: 55,
    threshold: 0.04,
    mode: :normal,
    below_sma_mult: 0.5,
    red_days_mult: 1.5
  },

    "MU1" => {
    days: 30,
    threshold: 0.02,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 0.5
  },

    "KKR2" => {
    days: 150,
    threshold: 0.03,
    mode: :strict,
    below_sma_mult: 0.5,
    red_days_mult: 5.0
  },

    "GOOGL2" => {
    days: 90,
    threshold: 0.20,
    mode: :strict,
    below_sma_mult: 5.5,
    red_days_mult: 0.0
  }

}

config = momentum_settings[base]

if config && i >= config[:days]

  past_close = closes[i - config[:days]].to_f

  if past_close > 0

    momentum = (close.to_f / past_close) - 1.0
    threshold = config[:threshold]

    # --- MODE LOGIC ---
    case config[:mode]

    when :strict

threshold *= config[:below_sma_mult] if sma100[i] && close < sma100[i]


  # count recent red days
  red_days = 0

  (1..3).each do |d|
    red_days += 1 if closes[i-d] < closes[i-d-1]
  end

  threshold *= config[:red_days_mult] if red_days >= 2

    when :normal
      # default behavior
      threshold *= 1.0

    when :lenient
      # easier during pullbacks
threshold *= 0.7 if close > sma100[i]
    end

    if momentum < threshold
      puts "[NO MOMENTUM BLOCK] #{symbol} #{date}" unless $FAST_SWEEP
      next
    end

  end
end


  ticker_name = symbol.split("_").first
  current_date = Date.parse(date[0,10])

# 1. ELITE FILTER
is_elite = true # Directly force this to true!
#master_elites = ["SMCI", "SMR", "NVDA", "VRT", "LRCX", "ARM", "VST", "CCJ", "GEV", 
#"CEG", "DELL", "AVGO", "PANW", "CYBR", "AMD", "MOD", 
#"FIX", "BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA", "MU", "QCOM", "TSM", "MRVL", "MA", "CAT", "DE",
#"GS", "MS", "JPM", "KKR", "META", "LLY", "TSLA", "COIN", "BLK", "GOOGL", "NVT"]

#is_elite = master_elites.include?(ticker_name)

# 2. GLOBAL RSI 8 LIMIT (The Win-Rate Booster)
# This forces the bot to only buy when the RSI is 8 or lower, ALWAYS.
if rsi2_at[i] > 20
  next
end

# 3. SMA 200 CIRCUIT BREAKER
if sma200 && sma200[i] && close < sma200[i]
  # If it's a bear market, we ONLY allow Elites.
  unless is_elite
    next 
  end
end

  # 2. PRE-CHECKS (Slot & Position)
  next if position 

  # 3. TIERED LIMITS
  # Use the same master_elites list for the 'Kings' tier
  kings     = Object.new.tap { |o| def o.include?(*); true; end }
  #kings     = master_elites
  surgicals = ["NET", "ASML", "QCOM", "BWXT"]
  volatiles = ["LEU", "UUUU"]

  if kings.include?(ticker_name)
    limit_rsi = 32
  elsif surgicals.include?(ticker_name)
    limit_rsi = 18
  elsif volatiles.include?(ticker_name)
    limit_rsi = 12
  else
    limit_rsi = 24
  end

  # 4. FINAL RSI & VIXY FILTERS
  if rsi2_at[i] && rsi2_at[i] > limit_rsi
    next 
  end

  # VIXY Bunker: Only the synchronized Elite/Kings list can pass
  if vixy_block_days > 0 && !kings.include?(ticker_name)
    next
  end

  # --- ENTRY EXECUTION ---
  # (Proceed with entry logic here...)


  # 4. THE EXECUTION (The point of no return)
  # Increment only after passing ALL filters
  $global_active_slots += 1 
  $active_tickers << ticker_name # 🛰️ Add name to the global list
  #puts "[SLOT OPENED] #{symbol} | Active Slots: #{$global_active_slots}/3"

  # Commit the position here
  # position = { ... }
    
  # --- EXECUTION ---
  # (Your code for opening the trade goes here...)

 # puts "[DEBUG BUY] #{symbol} #{date} close=#{close} rsi2=#{rsi2} rsi3=#{rsi3} breakout=#{breakout_signal}"

  # === Cooldown Rule (skip new BUYs if last SELL was too recent) ===
=begin
@last_sell_date ||= nil
if @last_sell_date
  last_sell = Date.parse(@last_sell_date) rescue nil
  current_date = Date.parse(date) rescue nil
if last_sell && current_date && (current_date - last_sell) < 3
  # Smart Cooldown:
  # Normally wait 3 days after a SELL,
  # but allow early BUY if RSI2 < 15 (very oversold)
  if rsi2 && rsi2 < 15
puts "[COOLDOWN OVERRIDE] RSI2=#{rsi2.round(2)} on #{date} → Early re-entry allowed!" unless $FAST_SWEEP
  else
    next  # skip BUY if not extremely oversold
  end
end
end
=end

# --- BUY diagnostics: reasons (RSI & ATR) -------------------------

log_line("")

buy_reasons = []

# --- helper for clean RSI logging ---
def describe_rsi(label, value, threshold = nil)
  # no data or obviously bogus
return "#{label} not ready (warmup)" if value.nil? || value < 0 || value > 100

  txt = "#{label} = #{value.round(2)}"
  if threshold && threshold.is_a?(Numeric)
    if value < threshold
      txt << " (below oversold #{threshold} → TRIGGERED)"
    else
      txt << " (above oversold #{threshold} → not triggered)"
    end
  elsif threshold
    txt << " (oversold param: #{threshold.inspect})"
  end
  txt
end

# figure out oversold threshold from your params/options
oversold_param =
  if defined?(oversold) && oversold.is_a?(Numeric)
    oversold
  elsif defined?(options) && options.respond_to?(:[]) && options[:oversold].is_a?(Numeric)
    options[:oversold]
  elsif defined?(sym_opts) && sym_opts.is_a?(Hash) && sym_opts[:oversold].is_a?(Numeric)
    sym_opts[:oversold]
  else
    nil
  end

# --- RSI2 ---
if defined?(rsi2)
  buy_reasons << describe_rsi("RSI2", rsi2, oversold_param)
end

# --- RSI3 ---
if defined?(rsi3)
  buy_reasons << describe_rsi("RSI3", rsi3, oversold_param)
end

# ATR info
if defined?(atr) && atr
  buy_reasons << "ATR available (#{atr.round(2)})"
end

unless buy_reasons.empty?
  log_line("[BUY_REASON] #{buy_reasons.join(', ')}")
end
# --- end BUY diagnostics: reasons --------------------------------

# ---- BUY diagnostics: filters (SMA, regime, FCX policy, breakout) --------
buy_filters = []

# --- SMA filter ---
sma_filter_param =
  if defined?(sym_opts) && sym_opts.is_a?(Hash) && sym_opts[:sma_filter].is_a?(Numeric)
    sym_opts[:sma_filter]
  elsif defined?(options) && options.respond_to?(:[]) && options[:sma_filter].is_a?(Numeric)
    options[:sma_filter]
  else
    nil
  end

if sma_filter_param
  label = "SMA#{sma_filter_param}"

  # Try to get the *current bar's* SMA value
  current_sma =
    if defined?(sma_value) && sma_value.is_a?(Numeric)
      # case 1: your strategy already stores a per-bar SMA value
      sma_value
    elsif defined?(sma200) && sma200.is_a?(Array)
      # case 2: sma200 is an array; find a loop index to use
      index =
        if defined?(idx)
          idx
        elsif defined?(i)
          i
        elsif defined?(bar_index)
          bar_index
        else
          nil
        end

      index ? sma200[index] : nil
    elsif defined?(sma200) && sma200.is_a?(Numeric)
      # rare case: SMA is already a single number
      sma200
    else
      nil
    end

  if current_sma
    if close > current_sma
      buy_filters << "#{label} filter ACTIVE (price #{close.round(2)} > #{label} #{current_sma.round(2)} → PASS)"
    else
      buy_filters << "#{label} filter ACTIVE (price #{close.round(2)} ≤ #{label} #{current_sma.round(2)} → BLOCK)"
    end
  else
    buy_filters << "#{label} filter ACTIVE but SMA value not ready (warmup)"
  end
else
  buy_filters << "No SMA filter active for this symbol"
end

# --- Regime filter (if you use it) ---
if defined?(regime_ok)
  buy_filters << (regime_ok ? "Regime filter: OK" : "Regime filter: BLOCKED")
end

# --- FCX volatility policy ---
if symbol.to_s.include?("FCX") && defined?(fcx_vol_ok)
  buy_filters << (fcx_vol_ok ? "FCXVol policy: OK" : "FCXVol policy: BLOCKED")
end

# --- Breakout filter ---
breakout_entry_param =
  if defined?(sym_opts) && sym_opts.is_a?(Hash) && sym_opts[:breakout_entry].is_a?(Numeric)
    sym_opts[:breakout_entry]
  elsif defined?(options) && options.respond_to?(:[]) && options[:breakout_entry].is_a?(Numeric)
    options[:breakout_entry]
  else
    nil
  end

if defined?(breakout_signal)
  case breakout_signal
  when :entry
    if breakout_entry_param
      buy_filters << "Breakout ENTRY TRIGGERED (#{breakout_entry_param}d high breakout)"
    else
      buy_filters << "Breakout ENTRY TRIGGERED (no days param logged)"
    end
  when :hold, :none, nil
    if breakout_entry_param
      buy_filters << "Breakout filter ACTIVE (#{breakout_entry_param}d) but NOT triggered on this bar"
    else
      buy_filters << "Breakout filter present but no entry days param"
    end
  when :exit
    buy_filters << "Breakout state: EXIT (should not be a buy trigger)"
  else
    buy_filters << "Breakout state: #{breakout_signal.inspect}"
  end
elsif breakout_entry_param
  buy_filters << "Breakout filter ACTIVE (#{breakout_entry_param}d) but breakout_signal not set"
else
  buy_filters << "No breakout filter active for this symbol"
end

unless buy_filters.empty?
  log_line("[BUY_FILTERS] #{buy_filters.join(', ')}")
end
# ---- end BUY diagnostics: filters --------------------------------


# --- BUY diagnostics: params snapshot -------------------------
buy_params_parts = []

# Prefer options hash if present
if defined?(options) && options.respond_to?(:[])
  atr_stop       = options[:atr_stop]
  atr_profit     = options[:atr_profit]
  rsi2_period    = options[:rsi2_period]
  rsi3_period    = options[:rsi3_period]
  oversold_param = options[:oversold]
  overbought_par = options[:overbought]
  be_days        = options[:breakout_entry] || options[:be]  
  bx_days        = options[:breakout_exit]  || options[:bx]  
  sma_filter     = options[:sma_filter]
elsif defined?(sym_opts) && sym_opts.is_a?(Hash)
  # Fallback to per-symbol overrides
  atr_stop       = sym_opts[:atr_stop]
  atr_profit     = sym_opts[:atr_profit]
  rsi2_period    = sym_opts[:rsi2_period]
  rsi3_period    = sym_opts[:rsi3_period]
  oversold_param = sym_opts[:oversold]
  overbought_par = sym_opts[:overbought]
  be_days        = sym_opts[:breakout_entry]
  bx_days        = sym_opts[:breakout_exit]
  sma_filter     = sym_opts[:sma_filter]
end

buy_params_parts << "ATR stop x#{atr_stop}"             if atr_stop
buy_params_parts << "ATR profit x#{atr_profit}"         if atr_profit
buy_params_parts << "RSI2 period #{rsi2_period}"        if rsi2_period
buy_params_parts << "RSI3 period #{rsi3_period}"        if rsi3_period
buy_params_parts << "Oversold < #{oversold_param}"      if oversold_param
buy_params_parts << "Overbought > #{overbought_par}"    if overbought_par
buy_params_parts << "Breakout entry #{be_days}d"        if be_days
buy_params_parts << "Breakout exit #{bx_days}d"         if bx_days
buy_params_parts << "SMA filter #{sma_filter}"          if sma_filter

unless buy_params_parts.empty?
  log_line("[BUY_PARAMS] #{buy_params_parts.join(', ')}")
end
# --- end BUY diagnostics: params snapshot ---------------------

msg = "BUY #{symbol} #{date} @ #{close}"
puts msg.green unless $FAST_SWEEP
log_line(msg)

# blank separator between BUY blocks in the TXT log
log_line("")

# === FCX loss-aware cooldown (skip 5 days after a losing FCX trade unless very oversold) ===
if symbol.to_s.include?("FCX")
  @last_fcx_loss ||= nil
  if @last_fcx_loss
    last_loss = Date.parse(@last_fcx_loss) rescue nil
    cur_date  = Date.parse(date) rescue nil
    if last_loss && cur_date && (cur_date - last_loss) < 5
      if rsi2 && rsi2 < 12
        puts "[FCX_COOLDOWN_OVR] RSI2=#{rsi2.round(1)} < 12 on #{date}" unless $FAST_SWEEP
      else
        next
      end
    end
  end
end

# --- Market regime gate: require QQQ above rising 200DMA
unless reg_ok
  next  # skip BUY in bear regime
end

size = 0.0
size_mult = 1.0   # ← collect all soft sizing here (trend, ATR cap, FCX policy)

# === TREND FILTER (soft) ===
=begin
if i >= 50
  sma50 = closes[(i-50)...i].sum / 50.0
  if close < sma50
    if ENV["TREND_SOFT"] == "1"
      size_mult *= (ENV["TREND_SOFT_MULT"] || "0.65").to_f  # default 0.65x
    else
      next  # keep your old hard skip if not enabled
    end
  end
end
=end

  # === SMA FILTER (usual gating) ===
  if sma_filter == 200
    size = 1.0 if sma200[i] && close > sma200[i]
  elsif sma_filter == 100
    size = 1.0 if sma100[i] && close > sma100[i]
  elsif sma_filter == 0
    size = 1.0
  end

# --- Extra FCX trend gate (keeps only healthiest FCX longs) ---
if symbol.to_s.include?("FCX")
  if ENV["FCX_TREND_HARD"] == "1"
    next unless sma200[i] && close > sma200[i]
  elsif ENV["FCX_TREND_SOFT"] == "1"
    size_mult *= (ENV["FCX_TREND_SOFT_MULT"] || "0.85").to_f unless (sma200[i] && close > sma200[i])
  end
end

# === ATR% CAP SIZING (soft) — with optional scoping ===
# Trim position size on very high daily volatility; do not skip the trade.
if ENV["ATR_CAP_ON"] == "1"
  # Scope: "ALL" (default), "FCX", or "HOT" (FCX+NVDA)
  scope = (ENV["ATR_CAP_SCOPE"] || "ALL").upcase
  in_scope =
    scope == "ALL" ||
    (scope == "FCX" && symbol.to_s.include?("FCX")) ||
    (scope == "HOT" && (symbol.to_s.include?("FCX") || symbol.to_s.include?("NVDA")))

  if in_scope
    atr_pct_for_size = (atr && close.to_f > 0) ? (atr.to_f / close.to_f) : 0.0
    cap_soft = (ENV["ATR_CAP_SOFT"] || "0.08").to_f   # you can tune these defaults
    cap_hard = (ENV["ATR_CAP_HARD"] || "0.14").to_f
    if atr_pct_for_size >= cap_hard
      size_mult *= (ENV["ATR_CAP_HARD_MULT"] || "0.85").to_f
    elsif atr_pct_for_size >= cap_soft
      size_mult *= (ENV["ATR_CAP_SOFT_MULT"] || "0.95").to_f
    end
  end
end

# --- FCX Volatility Policy (entry sizing only) ---

# Only apply when we're about to OPEN a position
if position.nil? && ENV["FCX_POLICIES_ON"] == "1"
  # ATR%
  atr_pct = if atr && close && close.to_f > 0
              atr.to_f / close.to_f
            else
              0.0
            end

  # Gap (open vs prev close)
  prev_close = (i && i > 0 ? closes[i-1] : nil)
  open_val   = (opens && i ? opens[i] : nil)
  gap = if open_val && prev_close && prev_close.to_f > 0
          (open_val.to_f - prev_close.to_f) / prev_close.to_f
        else
          nil   # ← important: keep nil when unknown
        end

  # Hard block: very high ATR% + big gap down
  if symbol.to_s.include?("FCX")
    hard       = (ENV["FCX_HARD"]       || "0.110").to_f
    kill_gapdn = (ENV["FCX_KILL_GAPDN"] || "0.040").to_f
    if atr_pct >= hard && !gap.nil? && gap <= -kill_gapdn
      puts "[FCX_BLOCK] #{date} ATR%=#{(atr_pct*100).round(1)} gap=#{(gap*100).round(1)}%"
      next
    end
  end

  # Ask policy for a downsizing multiplier / possible block
  applied = SymbolPolicies::FCXVolatilityPolicy.apply(
    {
      symbol:     symbol,
      atr_pct:    atr_pct,
      open:       open_val,
      prev_close: prev_close,
      dd60:       dd60_series[i]   
    },
      context: { reg_ok: reg_ok }
  )

  # If policy returns nil → block this entry
  next if applied.nil?

  # Otherwise apply size multiplier
  size_mult *= (applied[:size_multiplier] || 1.0).to_f

  # --- Audit (FCX only): BEFORE/AFTER applying multiplier
  if symbol.to_s.include?("FCX")
    audit_path = File.join(RESULTS_DIR, "fcx_policy_decisions.csv")
    header_needed = !File.exist?(audit_path)
    size_before = size
    size_after  = size * size_mult

    File.open(audit_path, "a") do |f|
      f.puts "date,symbol,atr_pct,size_before,size_after,size_mult" if header_needed
      f.puts [date, symbol, atr_pct, size_before, size_after, size_mult].join(",")
    end
  end
end

# --- Optional surge skip (kept as you had it) ---
if symbol.to_s.include?("FCX") && i && i >= 10 && closes && closes[i-10]
  ten_day_ret = (close.to_f / closes[i-10].to_f) - 1.0
  surge = (ENV["FCX_SURGE"] || "0.20").to_f  # 20%
  if ten_day_ret > surge
    puts "[FCX_SURGE_SKIP] #{date} ret10d=#{(ten_day_ret*100).round(1)}% > #{(surge*100).round(1)}%"
    next
  end
end

# ✅ Open a new position only if not already in one
size *= size_mult

if size > 0 && position.nil?
  # --- SAFE ATR FALLBACK ON ENTRY (do NOT skip the trade) ---
  real_atr = (atr && atr.to_f > 0.0) ? atr.to_f : nil
  if real_atr.nil?
    # Conservative one-day proxy ATR so we can open the trade safely
    fallback_atr = 0.02 * close.to_f     # tune 0.018–0.025 if you like
    size *= 0.85                         # temporary haircut for day 1
    atr  = fallback_atr
  else
    atr = real_atr
  end

position = {
  entry: close,
  entry_date: date,
  size: size,
  entry_wday: Date.parse(date[0,10]).wday,
  sell_logged: false,   

}

  signal   = "BUY"

  reason_lines = []

  if defined?(buy_reasons) && buy_reasons.respond_to?(:any?) && buy_reasons.any?
    reason_lines << "[BUY_REASON] #{buy_reasons.join(', ')}"
  end

  if defined?(buy_filters) && buy_filters.respond_to?(:any?) && buy_filters.any?
    reason_lines << "[BUY_FILTERS] #{buy_filters.join(', ')}"
  end

  if defined?(buy_params_line) && buy_params_line
    reason_lines << "[BUY_PARAMS] #{buy_params_line}"
  end

  reason_block = reason_lines.join("\n")

  # snapshot this REAL, committed buy
  log_committed_buy(symbol, date, close, reason_block)
  # ---------- END NEW -------------------------------------------------

  write_latest_buy(symbol, date, close, reason_block)
  # ---------- END NEW -------------------------------------------------
  
# increment slots ONLY after confirmed BUY

  unless existing_rows.include?([date, symbol, "BUY"])
    write_csv_unless_fast(multi_signal_path, [date, symbol, "BUY", close])
    existing_rows << [date, symbol, "BUY"]
  end
end

end

# --- UNIFIED & SAFE EXIT LOGIC ---
# Exit logic (works even if ATR missing)
if position
base = symbol.to_s.split("_").first.upcase


# exit_triggered = !reg_ok   # regime breaker

  exit_price = nil   

#  puts "[DBG_ENTER_EXIT_SECTION] #{symbol} #{date} exit_triggered=#{exit_triggered} exit_price=#{exit_price.inspect}"



=begin
# --- TAKE PROFIT (ATR OR % TARGET) ---
if position
  entry_price = position[:entry].to_f
  current_price = close.to_f
  current_profit = (current_price / entry_price) - 1.0

  # 1. ATR-Based Target
  atr_target_met = position[:target_price] && current_price >= position[:target_price].to_f

  # 2. Fixed Percentage Target (8%)
  percent_target_met = current_profit >= 0.15

  if atr_target_met || percent_target_met
    exit_triggered ||= true
    sell_signal = true

    exit_price =
      if opens && (i + 1) < opens.length && opens[i + 1]
        opens[i + 1].to_f
      else
        current_price
      end

    puts "[TAKE_PROFIT] #{symbol} | ATR:#{atr_target_met} | %:#{percent_target_met} | Profit: #{(current_profit*100).round(2)}%"
  end
end
=end

# --- STEP 3: THE SAFETY SEATBELT (Inside your Position/Exit loop) ---
if position

 # puts "[DEBUG] #{symbol} entry=#{position[:entry_date]} current=#{date}"

  # ELITE STOP
  ticker_name = symbol.split("_").first
  # The "Surgical Master" Elite List
  elites = Object.new.tap { |o| def o.include?(*); true; end }
 # elites = ["SMCI", "SMR", "NVDA", "VRT", "LRCX", "ARM", "VST", 
 # "CCJ", "GEV", "CEG", "DELL", "AVGO", "PANW", "CYBR", "AMD", 
 # "MOD", "FIX", "BTCUSD", "ETHUSD", "IBIT", "MSTR", "ETHA", "MU", "QCOM", "TSM", "MRVL", "MA", "CAT", "DE",
 # "GS", "MS", "JPM", "KKR", "META", "LLY", "TSLA", "COIN", "BLK", "GOOGL", "NVT"]

  entry_price = position[:entry].to_f
  pct_return = ((close.to_f - entry_price) / entry_price) * 100

#  if elites.include?(ticker_name) && pct_return < -2.0
#    exit_triggered ||= true
#    sell_signal = true
#    exit_reason = "ELITE_STOP_LOSS"
#    exit_price = (opens && (i + 1) < opens.length && opens[i + 1]) ? opens[i + 1].to_f : close.to_f

#    puts "[ELITE_STOP] #{symbol} #{pct_return.round(2)}%"
#  end

  # OTHER EXITS
  unless exit_triggered
    # RSI / breakout
  end
end



=begin
#EOD STOP
base = symbol.to_s.split("_").first

stop_pct = 6.0
stop_price = position[:entry].to_f * (1.0 - stop_pct / 100.0)

if close.to_f <= stop_price
  puts "[#{base}_STOP_TRIGGERED] #{symbol} #{date} close=#{close} stop=#{stop_price}" unless $FAST_SWEEP

  exit_triggered ||= true

  next_open =
    if opens && (i + 1) < opens.length && opens[i + 1]
      opens[i + 1].to_f
    else
      close.to_f
    end

  exit_price = next_open

  puts "[#{base}_STOP_NEXT_OPEN] #{symbol} #{date} stop=#{stop_price.round(2)} fill=#{next_open.round(2)} pct=#{stop_pct}" unless $FAST_SWEEP
end
=end

# --- Symbol-specific EOD Stop ---
base = symbol.to_s.split("_").first

stop_map = {
  "VRT"  => 25.0,
  "SMCI" => 16.0,
  "DELL" => 16.0,
  "VST"  => 16.0,
  "LRCX" => 14.5,
  "MOD"  => 10.5,
  "FIX"  => 10.5,
  "AVGO" => 11.0,
  "NVDA" => 9.0,    # default since not specified in your table
  "BTCUSD" => 16.0,    
  "ETHUSD" => 16.0,    
  "AMD" => 12.0, 
  "TSLA" => 8.0,    
   
  "MU" => 12.0   
#  "KKR" => 12.0    

}

stop_pct = stop_map.fetch(base, 6.0)   # Any stock not listed uses 6%

stop_price = position[:entry].to_f * (1.0 - stop_pct / 100.0)

if close.to_f <= stop_price
  puts "[#{base}_STOP_TRIGGERED] #{symbol} #{date} close=#{close} stop=#{stop_price.round(2)}" unless $FAST_SWEEP

  exit_triggered ||= true

  next_open =
    if opens && (i + 1) < opens.length && opens[i + 1]
      opens[i + 1].to_f
    else
      close.to_f
    end

  exit_price = next_open

  puts "[#{base}_STOP_NEXT_OPEN] #{symbol} #{date} stop=#{stop_price.round(2)} fill=#{next_open.round(2)} pct=#{stop_pct}" unless $FAST_SWEEP
end


=begin
# --- EOD stop -> NEXT OPEN exit (multi-symbol) ---
if position && !exit_triggered && !skip_stop # <--- The Gatekeeper
base = symbol.to_s.split("_").first

stop_pct = 9.0
stop_price = position[:entry].to_f * (1.0 - stop_pct / 100.0)

if close.to_f <= stop_price
  puts "[#{base}_STOP_TRIGGERED] #{symbol} #{date} close=#{close} stop=#{stop_price}" unless $FAST_SWEEP

  exit_triggered ||= true

  next_open =
    if opens && (i + 1) < opens.length && opens[i + 1]
      opens[i + 1].to_f
    else
      close.to_f
    end

  exit_price = next_open
  
  puts "[#{base}_STOP_NEXT_OPEN] #{symbol} #{date} stop=#{stop_price.round(2)} fill=#{next_open.round(2)} pct=#{stop_pct}" unless $FAST_SWEEP
end
end
# --- end multi-symbol stop ---
=end

=begin
# --- TWO-TIER SURGICAL SHIELD ---
base = symbol.to_s.split("_").first
skip_stop = (position && date == position[:entry_date])

if position && !exit_triggered && !skip_stop
  entry      = position[:entry].to_f
  
  # Define your two tiers
  intraday_stop_price = entry * 0.01 # 12% Intraday Emergency
  eod_stop_price      = entry * 0.09 # 9% EOD Filter

  # 1. Check Intraday First (Emergency)
  if low_m && low_m.to_f <= intraday_stop_price
    exit_triggered = true
    exit_reason = "INTRADAY_12"
  
  # 2. Check EOD Second (Closing Filter)
  elsif close.to_f <= eod_stop_price
    exit_triggered = true
    exit_reason = "EOD_9"
  end

  if exit_triggered
    # Calculate Next Open Fill
    next_open = (opens && (i + 1) < opens.length && opens[i + 1]) ? opens[i+1].to_f : close.to_f
    exit_price = next_open

    puts "[#{base}_STOP] #{date} #{exit_reason} | Stop: #{eod_stop_price.round(2)} | Fill: #{exit_price.round(2)}" unless $FAST_SWEEP
  end
end
=end


# ==============================================================================
# STRATEGY OVERRIDE: ANET EOD Stop-Loss & Next-Open Execution
# Logic: Triggers an exit if the Close is <= the Stop Price. 
# Execution: Fills at the Open of the subsequent bar to simulate non-intraday trading.
# ==============================================================================
=begin
# --- ANET EOD stop -> NEXT OPEN exit (realistic, no mid-day trading) ---
if symbol.to_s.split("_").first == "ANET"
  anet_stop_pct = 100  # tweak this
  stop_price    = position[:entry].to_f * (1.0 - anet_stop_pct / 100.0)

  # If we closed below the stop, we exit at the NEXT bar's open
  if close.to_f <= stop_price
    puts "[ANET_STOP_TRIGGERED] #{symbol} #{date} close=#{close} stop=#{stop_price}" unless $FAST_SWEEP

    exit_triggered ||= true

    next_open =
      if opens && (i + 1) < opens.length && opens[i + 1]
        opens[i + 1].to_f
      else
        close.to_f
      end

    exit_price = next_open  # ✅ don't overwrite close

    puts "[ANET_STOP_NEXT_OPEN] #{symbol} #{date} stop=#{stop_price.round(2)} fill=#{next_open.round(2)} pct=#{anet_stop_pct}" unless $FAST_SWEEP
  end
end
# --- end ANET EOD stop -> NEXT OPEN ---
=end

  # --- PATCH B: universal hard stop (works even if ATR is nil)
  if close <= position[:entry] * (1.0 - HARD_STOP_PCT/100.0)
    exit_triggered = true
    puts "[HARD_STOP] #{symbol} #{date} exit @ #{close} (entry #{position[:entry]}, -#{HARD_STOP_PCT}%)" unless $FAST_SWEEP
  end

  # --- Calculate stops only if ATR available and positive ---
  if atr && atr.to_f > 0.0
    position[:highest] ||= position[:entry]
    position[:highest]  = [position[:highest], close].max

    prev_atr = if i >= 10 && atr_vals[i-10] && atr_vals[i-10].to_f > 0.0
      atr_vals[i-10].to_f
    else
      atr.to_f
    end

    atr_ratio = (atr.to_f / prev_atr).clamp(0.5, 1.5)

    adaptive_stop_mult   = (atr_stop   || $atr_stop).to_f   * atr_ratio
    base_profit_mult     = (atr_profit || $atr_profit).to_f
    adaptive_profit_mult = begin
      tmp = base_profit_mult * (3.3 - atr_ratio)
      [[tmp, base_profit_mult * 0.8].max, base_profit_mult * 1.4].min
    end

    # === FCX policy: refine exit multipliers BEFORE we compute stops/targets
    if symbol.to_s.include?("FCX") && ENV["FCX_POLICIES_ON"] == "1"
      atr_pct_bar = (atr && close && close > 0) ? (atr.to_f / close.to_f) : 0.0

      prev_close = (i > 0 ? closes[i-1] : nil)
      prev_prev  = (i > 1 ? closes[i-2] : nil)
      prev_ret   = (prev_close && prev_prev && prev_prev.to_f > 0) ? (prev_close/prev_prev - 1.0) : nil

      pol = SymbolPolicies::FCXVolatilityPolicy.apply(
        {
          symbol:     symbol,
          atr_pct:    atr_pct_bar,
          open:       (opens && i ? opens[i] : nil),
          prev_close: prev_close,
          dd60:       dd60_series[i],
          prev_ret:   prev_ret
        },
        context: { reg_ok: reg_ok }
      )
      if pol
        adaptive_stop_mult   *= (pol[:stop_mult]   || 1.0)
        adaptive_profit_mult *= (pol[:profit_mult] || 1.0)
      end

      if ENV["FCX_VOL_LOG"] == "1"
        puts "[FCX_EXIT_ADAPT] #{date} atr%=#{(atr_pct_bar*100).round(2)} " \
             "stop_mult=#{adaptive_stop_mult.round(3)} profit_mult=#{adaptive_profit_mult.round(3)}"
      end
    end

    # Safety clamps so multipliers stay sane
    base_stop   = (atr_stop   || $atr_stop).to_f
    base_profit = (atr_profit || $atr_profit).to_f
    adaptive_stop_mult   = [[adaptive_stop_mult,   0.5 * base_stop].max,   2.0 * base_stop].min
    adaptive_profit_mult = [[adaptive_profit_mult, 0.6 * base_profit].max, 1.6 * base_profit].min

    # Compute levels ONCE (no duplicates)
    trailing_stop = position[:highest] - (adaptive_stop_mult * atr.to_f)
    target_level  = position[:entry]   + (adaptive_profit_mult * atr.to_f)

    exit_triggered ||= (close <= trailing_stop || close >= target_level)
  end

  # Always allow explicit SELL
  exit_triggered ||= (chosen_signal == "SELL")

=begin
# --- Trailing profit give-back (ETH only, no ATR needed) ---
if position && eth_sym?(symbol)
  position[:peak] ||= position[:entry]
  position[:peak]  = [position[:peak], close].max
  drop_pct = (position[:peak] - close) / position[:peak] * 100.0
  arm_mult = 1.22   # ✅ +20% (not +10%)
  giveback = 9.5    # -8% from peak
  exit_triggered ||= (drop_pct >= giveback && position[:peak] > position[:entry] * arm_mult)
end

# --- Trailing profit give-back (BTC only, no ATR needed) ---
if position && btc_sym?(symbol)
  position[:peak] ||= position[:entry]
  position[:peak]  = [position[:peak], close].max
  drop_pct = (position[:peak] - close) / position[:peak] * 100.0
  arm_mult = 1.23   # ✅ +10%
  giveback = 7.9    # -8% from peak
  exit_triggered ||= (drop_pct >= giveback && position[:peak] > position[:entry] * arm_mult)
end
=end

=begin
# --- Universal trailing profit give-back ---
  if position
    position[:peak] ||= position[:entry]
    position[:peak]  = [position[:peak], close].max

    drop_pct = (position[:peak] - close) / position[:peak] * 100.0

    arm_mult = 1.06   # # +6% profit required to activate
    giveback = 2.0    # give back 2% from peak

    if drop_pct >= giveback && position[:peak] > position[:entry] * arm_mult
      puts "[TRAILING_GIVEBACK] #{symbol} #{date} peak=#{position[:peak].round(2)} close=#{close.round(2)} drop=#{drop_pct.round(2)}%" unless $FAST_SWEEP
      exit_triggered ||= true
    end
  end
=end 

  # --- Execute exit if triggered ---
if exit_triggered
fill = exit_price || close

  if exit_price
     # puts "[DEBUG_NEXT_OPEN_FILL] #{symbol} #{date} close=#{close} next_open_fill=#{fill}"
  end

  trades << {
    symbol: symbol,
    entry_date: position[:entry_date],
    exit_date:  date,
    entry:      position[:entry],
    exit:       fill,
    pct_return: ((fill - position[:entry]) / position[:entry] * 100.0 * position[:size]).round(2)
  }
  @last_sell_date = date
  @last_fcx_loss  = date if symbol.to_s.include?("FCX") && trades.last[:pct_return].to_f < 0

  # ✅ NEW: record the SELL signal for this actual exit
  sell_key = [date, symbol, "SELL"]
  unless existing_rows.include?(sell_key)
  write_csv_unless_fast(multi_signal_path, [date, symbol, "SELL", fill])
    existing_rows << sell_key
  end

  # ---- SELL reasons (printed to CMD only) ----
  sell_reasons = []
  sell_reasons << "ATR stop-loss hit"         if defined?(atr_stop)   && atr_stop   && close <= atr_stop
  sell_reasons << "ATR profit target hit"     if defined?(atr_profit) && atr_profit && close >= atr_profit
  sell_reasons << "Breakout exit triggered"   if defined?(breakout_signal) && breakout_signal == :exit
  sell_reasons << "RSI2 extremely overbought" if defined?(rsi2) && rsi2 && rsi2 > 90
  sell_reasons << "RSI3 extremely overbought" if defined?(rsi3) && rsi3 && rsi3 > 90
  sell_reasons << "General exit condition met" if sell_reasons.empty?

  puts "[REASON] #{sell_reasons.join(', ')}" unless $FAST_SWEEP

msg = "SELL #{symbol} #{date} @ #{fill} → #{trades.last[:pct_return]}%"
  log_line(msg)
  puts msg.red unless $FAST_SWEEP

  position = nil
end
end

=begin

# --- Execute exit if triggered ---
if exit_triggered && position
  trades << {
    symbol: symbol,
    entry_date: position[:entry_date],
    exit_date: date,
    entry: position[:entry],
    exit: close,
    pct_return: ((close - position[:entry]) / position[:entry] * 100 * position[:size]).round(2)
  }

# ===== SELL REASONS =====
sell_reasons = []

# ATR stop-loss
if defined?(atr_stop) && atr_stop && close <= atr_stop
  sell_reasons << "ATR stop-loss hit"
end

# ATR profit target
if defined?(atr_profit) && atr_profit && close >= atr_profit
  sell_reasons << "ATR profit target hit"
end

# Breakout exit
sell_reasons << "Breakout exit triggered" if breakout_signal == :exit

# RSI exits
sell_reasons << "RSI2 extremely overbought" if rsi2 && rsi2 > 90
sell_reasons << "RSI3 extremely overbought" if rsi3 && rsi3 > 90

# Fallback
sell_reasons << "General exit condition met" if sell_reasons.empty?

reason_text = sell_reasons.uniq.join(", ")

# ===== OUTPUT =====
msg = "SELL #{symbol} #{date} @ #{close} → #{trades.last[:pct_return]}% (#{reason_text})"
puts msg.red unless $FAST_SWEEP
log_line(msg)


#puts "🟥 SELL #{symbol} #{date} @ #{close} → #{trades.last[:pct_return]}%".red unless $FAST_SWEEP

  # ✅ Record last sell date for cooldown rule
  @last_sell_date = date

  if symbol.to_s.include?("FCX") && trades.last[:pct_return].to_f < 0
    @last_fcx_loss = date
  end

  # ✅ NEW: also write a SELL signal for this actual exit
  #sell_key = [date, symbol, "SELL"]
  #unless existing_rows.include?(sell_key)
   # write_csv_unless_fast(multi_signal_path, [date, symbol, "SELL", close])
   # existing_rows << sell_key
  #end

  position = nil
end

=end
  
# ✅ append BUY/SELL only once per (date, symbol, signal)
if ["BUY", "SELL"].include?(chosen_signal)
  key = [date, symbol, chosen_signal]
  unless existing_rows.include?(key)
write_csv_unless_fast(multi_signal_path, [date, symbol, chosen_signal, close])
    existing_rows << key  # 🧠 add to memory so it's not re-added later
  end

  signals << { date: date, symbol: symbol, signal: chosen_signal, close: close }

end

# ==========================================================
# 🕒 VIXY CLOCK 
# ==========================================================
vixy_block_days -= 1 if vixy_block_days > 0

end

=begin
# === FINAL SAFEGUARD: Close any open position at end of data ===
if position
  trades << {
    symbol: symbol,
    entry_date: position[:entry_date],
    exit_date: dates.last,
    entry: position[:entry],
    exit: closes.last,
    pct_return: ((closes.last - position[:entry]) / position[:entry] * 100).round(2)
  }

  # ✅ also write SELL for end-of-data close
  sell_key = [dates.last, symbol, "SELL"]
  unless existing_rows.include?(sell_key)
    write_csv_unless_fast(multi_signal_path, [dates.last, symbol, "SELL", closes.last])
    existing_rows << sell_key
  end

  if symbol.to_s.include?("FCX") && trades.last[:pct_return].to_f < 0
    @last_fcx_loss = dates.last
  end

  position = nil
end
=end


# === SAVE SIGNAL FILE (PER SYMBOL, OVERWRITE EACH RUN) ===
unless $FAST_SWEEP
  signal_path = File.join(RESULTS_DIR, "#{symbol}_signals.csv")
  CSV.open(signal_path, "w") do |csv|
    csv << %w[date symbol signal close]
    signals.each { |s| csv << [s[:date], s[:symbol], s[:signal], s[:close]] }
  end
  puts "[SAVED] #{signal_path} (rewrote #{signals.size} total signals)"
end
return [trades, signals, dates.first, dates.last]   # ✅ add this

end
