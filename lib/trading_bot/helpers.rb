def rsi2_cfg
  { period: $rsi2_period, oversold: $oversold, overbought: $overbought }
end

def rsi3_cfg
  { period: $rsi3_period, oversold: $oversold, overbought: $overbought }
end

def breakout_entry; $breakout_entry; end
def breakout_exit;  $breakout_exit;  end


ATR_PERIOD      = 14 
ATR_STOP_MULT   = 3.0   # 3x ATR stop loss
ATR_PROFIT_MULT = 6.0   # 6x ATR take profit

def grade_label(pf:, win:, cagr:, maxdd:, trades:)
  return ["Low", "❌"] if trades.to_i < 20
  if trades >= 40 && pf.to_f >= 1.6 && win.to_f >= 60 && maxdd.to_f <= 20 && cagr.to_f > 6
    ["Excellent", "✅"]
  elsif trades >= 30 && pf.to_f >= 1.3 && win.to_f >= 55 && maxdd.to_f <= 25 && cagr.to_f > 3
    ["Solid", "✅"]
  elsif trades >= 20 && pf.to_f >= 1.1 && win.to_f >= 50 && maxdd.to_f <= 30
    ["Borderline", "⚠️"]
  else
    ["Low", "❌"]
  end
end

# ===============================
# HELPERS
# ===============================
def btc_sym?(s)
 s.to_s.include?("BTCUSDNOWEEKENDS_GoogleFinance_AutoUpToDate")
end

def eth_sym?(s)
  s.to_s.include?("ETHAUSDNOWEEKENDS_GoogleFinance_AutoUpToDate")
end

def build_tomorrow_orders_like_backup!(path, all_trades, latest_signals)

  rows = []

  # 1. Add ALL completed trades (BUY + SELL)
  all_trades.each do |t|
    rows << [
      t[:entry_date],
      t[:symbol],
      "BUY",
      t[:entry],
      "PENDING",
      ""
    ]

    rows << [
      t[:exit_date],
      t[:symbol],
      "SELL",
      t[:exit],
      "",
      "PENDING"
    ]
  end

  # 2. Add CURRENT open BUY (if exists)
  latest_signals.each do |sym, info|
    next unless info[:signal].to_s.upcase == "BUY"

    # skip if already in trades (already opened)
    already_open = all_trades.any? do |t|
      t[:symbol] == sym && t[:exit_date].nil?
    end

    next if already_open

puts "[ADDING ORDER] #{sym} #{info[:date]} " \
     "SIGNAL=BUY " \
     "CLOSE=#{info[:close]}"

    rows << [
      info[:date],
      sym,
      "BUY",
      info[:close],
      "PENDING",
      ""
    ]
  end

  # 3. Sort everything by date
  rows.sort_by! { |r| Date.parse(r[0]) rescue Date.new(0) }

  CSV.open(path, "w") do |csv|
    csv << ["date","symbol","signal","close","executed_entry","executed_exit"]
    rows.each { |r| csv << r }
  end
end

def build_tomorrow_orders_from_latest_signals!(path, latest_signals)

  CSV.open(path, "w") do |csv|
    csv << ["date","symbol","signal","close","executed_entry","executed_exit"]

      today = Date.today
      action_date = next_trading_day_str(today.to_s)

    latest_signals.each do |symbol, info|
      sig = info[:signal].to_s.upcase
      next unless ["BUY", "SELL"].include?(sig)

      executed_entry = (sig == "BUY")  ? "PENDING" : ""
      executed_exit  = (sig == "SELL") ? "PENDING" : ""

      csv << [
        action_date,
        symbol,
        sig,
        info[:close],
        executed_entry,
        executed_exit
      ]
    end
  end
end

def build_tomorrow_orders_from_all_signals!(path, all_signals)

  CSV.open(path, "w") do |csv|
    csv << ["date","symbol","signal","close","executed_entry","executed_exit"]

    all_signals
      .sort_by { |s| Date.parse(s[:date]) rescue Date.new(0) }
      .each do |s|

        sig = s[:signal].to_s.upcase
        next unless ["BUY", "SELL"].include?(sig)

        action_date = next_trading_day_str(s[:date])

        executed_entry = (sig == "BUY")  ? "PENDING" : ""
        executed_exit  = (sig == "SELL") ? "PENDING" : ""

        csv << [
          action_date,
          s[:symbol],
          sig,
          s[:close],
          executed_entry,
          executed_exit
        ]
      end
  end
end

def verify_tomorrow_orders_vs_trades(trades, path)

  return unless File.exist?(path)

  rows = CSV.read(path, headers: true)

  buys  = rows.count { |r| r["signal"] == "BUY" }
  sells = rows.count { |r| r["signal"] == "SELL" }

  trades_count = trades.size

  puts "\n📊 VERIFY TOMORROW ORDERS"
  puts "----------------------------------"
  puts "Trades: #{trades_count}"
  puts "BUYs  : #{buys}"
  puts "SELLs : #{sells}"

  if buys == trades_count && sells == trades_count
    puts "✅ PERFECT MATCH"
  else
    puts "❌ MISMATCH DETECTED"

    puts "→ BUY mismatch (expected #{trades_count})" if buys != trades_count
    puts "→ SELL mismatch (expected #{trades_count})" if sells != trades_count
  end

  puts "----------------------------------\n"
end

def rebuild_tomorrow_orders_from_trades!(path, trades)

  CSV.open(path, "w") do |csv|
    csv << ["date","symbol","signal","close","executed_entry","executed_exit"]

    trades.each do |t|
      entry_date = next_trading_day_str(t[:entry_date])
      exit_date  = next_trading_day_str(t[:exit_date])

      # BUY
      csv << [entry_date, t[:symbol], "BUY", t[:entry], "PENDING", ""]

      # SELL
      csv << [exit_date, t[:symbol], "SELL", t[:exit], "", "PENDING"]
    end
  end
end

#------------------------ For Sell tomorrow_orders Beginning ----------

def next_trading_day_str(date)
  d = Date.parse(date.to_s)
  d += 1
  d += 1 while d.saturday? || d.sunday?
  d.to_s
rescue
  date.to_s
end

def reset_tomorrow_orders!(path)
  FileUtils.mkdir_p(File.dirname(path))
  CSV.open(path, "w") do |csv|
    csv << ["date","symbol","signal","close","executed_entry","executed_exit"]
  end
end

def append_tomorrow_order!(path, signal:, symbol:, signal_date:, close_price:)
  action_date = next_trading_day_str(signal_date)
  sig = signal.to_s.upcase
  executed_entry = (sig == "BUY")  ? "PENDING" : ""
  executed_exit  = (sig == "SELL") ? "PENDING" : ""
  new_row = [action_date, symbol, sig, close_price.to_f, executed_entry, executed_exit]
  existing = File.exist?(path) ? CSV.read(path, headers: true) : []

# 🚫 prevent exact duplicate (same symbol + same signal + same date)
return if existing.any? do |r|
  r["symbol"] == symbol &&
  r["signal"] == sig &&
  r["date"] == action_date
end

  CSV.open(path, "a") do |csv|
    csv << new_row
  end
end

# -------------------------------------------------------------------
# Log a REAL, committed BUY to logs/committed_buys.log
# -------------------------------------------------------------------
def log_committed_buy(symbol, date, price, reason_block = nil)
  log_dir  = File.join(BOT_ROOT, "logs")
  log_file = File.join(log_dir, "committed_buys.log")

  FileUtils.mkdir_p(log_dir)

  File.open(log_file, "a") do |f|
    f.puts "=============================="
    f.puts "BUY   #{symbol}"
    f.puts "DATE  #{date}"
    f.puts "PRICE #{'%.2f' % price}"

    if reason_block && !reason_block.strip.empty?
      f.puts "--- REASONS ---"
      f.puts reason_block
    end

    f.puts
  end
end
# -------------------------------------------------------------------

# --- latest BUY snapshot (for live trading) ---------------------
LATEST_BUY_FILE = File.join(RESULTS_DIR, "hybrid_v3_latest_buy.txt")

#------------------------ For Sell tomorrow_orders Beginning ----------
TOMORROW_ORDERS_CSV = File.join(RESULTS_DIR, "tomorrow_orders.csv")
#------------------------ For Sell tomorrow_orders END ----------

def write_latest_buy(symbol, date, price, reason_block = nil)
  new_date = Date.parse(date.to_s) rescue nil

  # If file already exists, only overwrite if this date is newer
  if File.exist?(LATEST_BUY_FILE)
    existing = File.read(LATEST_BUY_FILE)

    if existing =~ /^DATE:\s+(.+)$/
      existing_date_str = $1.strip
      existing_date = Date.parse(existing_date_str) rescue nil

      if existing_date && new_date && existing_date >= new_date
        # Existing is same or newer → do NOT overwrite
        return
      end
    end
  end

  # Either no file yet, or this buy is newer → write it
  File.open(LATEST_BUY_FILE, "w") do |f|
    f.puts "SYMBOL: #{symbol}"
    f.puts "DATE:   #{date}"
    f.puts "PRICE:  #{price}"
    f.puts
    f.puts reason_block if reason_block && !reason_block.empty?
  end
end
# --------------------------------------------------------------

def googl_symbol?(s)
  s.to_s.include?("GOOGL_GoogleFinance_AutoUpToDate")
end

def detect_sep(path)
  first = File.open(path, 'r') { |io| io.gets.to_s }
  return "\t" if first.include?("\t")
  return ";" if first.count(";") > first.count(",")
  ","
end

# Calculates RSI using a Simple Moving Average (SMA) approach.
# Returns an array of [index, rsi_value] pairs.
# Note: For RSI-2 mean-reversion, this SMA version reacts faster than Wilder's.
def calculate_rsi(closes, period)
  # Guard clause: Ensure we have enough data points to fill the first window
  return [] if closes.size < period + 1

  # Calculate deltas (size will be closes.size - 1)
  gains, losses = [], []

  # Convert price action into raw gains and losses between consecutive days
  closes.each_cons(2) do |prev, curr|
    change = curr - prev
    gains << [change, 0].max
    losses << [0, -change].max
  end

  rsi_values = []

  # Iterate from the first point where we have enough data
  period.upto(closes.size - 1) do |i|
    # Sum gains and losses over the most recent 'period' days
    avg_gain = gains[(i - period)...i].sum / period.to_f
    avg_loss = losses[(i - period)...i].sum / period.to_f

    # Robust RSI calculation addressing division-by-zero and zero-volatility
    rsi = if avg_gain.zero? && avg_loss.zero?
            50.0  # Flat price / no movement = neutral momentum
          elsif avg_loss.zero?
            100.0 # Pure green streak = maximum overbought
          elsif avg_gain.zero?
            0.0   # Pure red streak = maximum oversold
          else
            rs = avg_gain / avg_loss
            100.0 - (100.0 / (1.0 + rs))
          end

    # Store with index 'i' to align the signal with the specific closing price
    rsi_values << [i, rsi]
  end

  rsi_values
end

def calculate_atr(rows, period = ATR_PERIOD)
  highs  = rows['high'].map(&:to_f)
  lows   = rows['low'].map(&:to_f)
  closes = rows['close'].map(&:to_f)

  trs = []
  (1...rows.size).each do |i|
    tr = [
      highs[i] - lows[i],
      (highs[i] - closes[i-1]).abs,
      (lows[i] - closes[i-1]).abs
    ].max
    trs << tr
  end

  atr = []
  period.upto(trs.size) do |i|
    atr << trs[(i-period)...i].sum / period.to_f
  end
  # pad with nils at start so indexes match closes[]
  Array.new(rows.size - atr.size, nil) + atr
end

def compute_stats(rows, start_date, end_date)
  return { trades: 0, win_rate: 0, pf: 0, cagr: 0 } if rows.empty?
  wins   = rows.select { |r| r[:pct_return] > 0 }
  losses = rows.select { |r| r[:pct_return] < 0 }
  gross_win  = wins.sum { |r| r[:pct_return] }
  gross_loss = losses.sum { |r| r[:pct_return].abs }
  pf = gross_loss.zero? ? 9_999.0 : gross_win / gross_loss
  years = [(Date.parse(end_date) - Date.parse(start_date)).to_f / 365.0, 0.01].max
  equity = rows.inject(1.0) { |eq, r| eq * (1 + r[:pct_return] / 100.0) }
  cagr = ((equity) ** (1.0 / years) - 1) * 100.0
  { trades: rows.size, win_rate: (wins.size.to_f / rows.size * 100.0), pf: pf, cagr: cagr }
end

# === Console helpers (global) ===
def print_yearly_table(path, title: "Yearly Breakdown")
  unless File.exist?(path)
    puts "[WARN] Missing: #{path}"
    return
  end
  rows = CSV.read(path, headers: true)
  puts "-------------------------------------------------------------"
  puts title
  puts "Year  Trades  Start        End          Compounded"
  rows.each do |r|
    y  = r["year"]
    tr = r["trades"].to_i
    sb = (r["start_balance"] || r["start"]).to_f
    eb = (r["end_balance"]   || r["end"]).to_f
    cr = (r["realistic_compounded_return"] || r["compounded_return"] || 0).to_f
    printf "%-5s %-7d $%-11.2f $%-12.2f %8.2f%%\n", y, tr, sb, eb, cr
  end
  puts "-------------------------------------------------------------"
end

def compare_yearly(current_csv:, nextopen_csv:)
  unless File.exist?(current_csv); puts "[WARN] Missing: #{current_csv}"; return; end
  unless File.exist?(nextopen_csv); puts "[WARN] Missing: #{nextopen_csv}"; return; end

  cur = {}; CSV.foreach(current_csv, headers: true)  { |r| cur[r["year"].to_i] = r }
  nxt = {}; CSV.foreach(nextopen_csv, headers: true) { |r| nxt[r["year"].to_i] = r }

  years = (cur.keys + nxt.keys).uniq.sort
  puts "-------------------------------------------------------------"
  puts "Next-Open (What-If) vs Current — Yearly"
  puts "Year  CurComp   NxtComp   ΔComp    CurEnd       NxtEnd       ΔEnd"
  years.each do |y|
    c = cur[y]; n = nxt[y]
    cc = (c && (c["realistic_compounded_return"] || c["compounded_return"]))&.to_f || 0.0
    nc = (n && (n["realistic_compounded_return"] || n["compounded_return"]))&.to_f || 0.0
    ce = c ? (c["end_balance"] || c["end"]).to_f : 0.0
    ne = n ? (n["end_balance"] || n["end"]).to_f : 0.0
    printf "%-5d %7.2f%% %8.2f%% %7.2f%%  $%-11.2f $%-11.2f %8.2f\n",
           y, cc, nc, (nc - cc), ce, ne, (ne - ce)
  end
  puts "-------------------------------------------------------------"
end

# ===============================
# BACKTEST
# ===============================

#------------------------ For Sell tomorrow_orders Beginning ----------
reset_tomorrow_orders!(TOMORROW_ORDERS_CSV)
#------------------------ For Sell tomorrow_orders END ----------

