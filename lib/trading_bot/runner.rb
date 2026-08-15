# ===============================
# COMMAND LINE
# ===============================
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby trading_bot.rb --symbols SYMBOL1,SYMBOL2 [options]"
  opts.on("--symbols x,y,z", Array, "Comma-separated list of symbols") { |list| options[:symbols] = list }
  opts.on("--one-trade", "Only one open trade across ALL symbols") { options[:one_trade] = true }
  opts.on("--atr-stop N", Float, "ATR stop multiplier (default #{ATR_STOP_MULT})") { |v| options[:atr_stop] = v }
  opts.on("--start-equity N", Float, "Starting equity for simulations (default 1000)") { |v| options[:start_equity] = v }
  opts.on("--profile NAME", String, "Storage profile (e.g. live, research)") { |v| options[:profile] = v }
  opts.on("--bot NAME", String, "Bot name (e.g. conservative, highlow)")     { |v| options[:bot]     = v }
  opts.on("--from DATE", String, "Start date YYYY-MM-DD") { |v| options[:from] = Date.parse(v) rescue nil }
  opts.on("--to DATE",   String, "End date YYYY-MM-DD")   { |v| options[:to]   = Date.parse(v) rescue nil }
  opts.on("--atr-profit N", Float, "ATR profit multiplier (default #{ATR_PROFIT_MULT})") { |v| options[:atr_profit] = v }
  opts.on("--sma-filter N", Integer, "SMA filter length (100, 200, or 0=off)") { |v| options[:sma_filter] = v }
  opts.on("--sweep", "Run parameter sweep instead of normal run") { options[:sweep] = true }
  # RSI options
  opts.on("--rsi2-period N", Integer, "RSI2 period (default 2)") { |v| options[:rsi2_period] = v }
  opts.on("--rsi3-period N", Integer, "RSI3 period (default 3)") { |v| options[:rsi3_period] = v }
  opts.on("--oversold N", Integer, "Oversold threshold (default 5)") { |v| options[:oversold] = v }
  opts.on("--overbought N", Integer, "Overbought threshold (default 95)") { |v| options[:overbought] = v }
  # Breakout options
  opts.on("--breakout-entry N", Integer, "Breakout entry window (default 20)") { |v| options[:breakout_entry] = v }
  opts.on("--breakout-exit N", Integer, "Breakout exit window (default 10)") { |v| options[:breakout_exit] = v }
end.parse!

# ---- Start equity (env/CLI) ----
$start_equity = (options[:start_equity] || ENV["START_EQUITY"] || "1000").to_f
puts "[CONFIG] Start equity = $#{$start_equity}"

# --- EARLY BOOTSTRAP STORAGE (pre-OptionParser; minimal) ---
early_profile = ENV["BOT_PROFILE"] || ENV["BOT_NAMESPACE"] || "default"
early_bot     = ENV["BOT_NAME"]    || "vanilla"
RESULTS_DIR = File.join(BASE_DIR, "storage", early_profile, early_bot)
FileUtils.mkdir_p(RESULTS_DIR) rescue nil
ENV["METRICS_CSV"] ||= File.join(RESULTS_DIR, "metrics", "latest.csv")
FileUtils.mkdir_p(File.dirname(ENV["METRICS_CSV"])) rescue nil
SWEEP_LIVE = File.join(RESULTS_DIR, "sweep_live.csv")
SWEEP_BEST = File.join(RESULTS_DIR, "sweep_best_so_far.csv")

# --- Namespaced storage (profile/bot) ---
begin
  Object.send(:remove_const, :RESULTS_DIR) if defined?(RESULTS_DIR)
  Object.send(:remove_const, :SWEEP_LIVE)  if defined?(SWEEP_LIVE)
  Object.send(:remove_const, :SWEEP_BEST)  if defined?(SWEEP_BEST)
rescue NameError
end

# derive namespace parts (CLI wins, then env fallbacks)
ns_profile = (options[:profile] || ENV["BOT_PROFILE"] || ENV["BOT_NAMESPACE"] || "default").to_s
ns_bot     = (options[:bot]     || ENV["BOT_NAME"]     || "vanilla").to_s

NS = File.join(ns_profile, ns_bot)   # e.g. "research/v3" or "live/vanilla"

RESULTS_DIR = File.join(BASE_DIR, "storage", NS)
FileUtils.mkdir_p(RESULTS_DIR) rescue nil

# Point METRICS_CSV under the namespace unless caller already set it
ENV["METRICS_CSV"] ||= File.join(RESULTS_DIR, "metrics", "latest.csv")
begin
  FileUtils.mkdir_p(File.dirname(ENV["METRICS_CSV"])) rescue nil
rescue => e
  warn "[METRICS_DIR_ERR] #{e.class}: #{e.message}"
end

# Sweep files live under the same RESULTS_DIR
SWEEP_LIVE = File.join(RESULTS_DIR, "sweep_live.csv")
SWEEP_BEST = File.join(RESULTS_DIR, "sweep_best_so_far.csv")

# Keep METRICS_CSV pointing inside the new namespaced storage if it looks like a default
if ENV["METRICS_CSV"].to_s.strip.empty? || ENV["METRICS_CSV"].to_s.include?("/storage/")
  ENV["METRICS_CSV"] = File.expand_path(File.join(RESULTS_DIR, "metrics", "latest.csv"))
end
FileUtils.mkdir_p(File.dirname(ENV["METRICS_CSV"])) rescue nil

puts "[STORAGE] profile=#{ns_profile} bot=#{ns_bot}"
puts "[STORAGE] RESULTS_DIR → #{RESULTS_DIR}"
puts "[STORAGE] METRICS_CSV → #{ENV['METRICS_CSV']}"

# === Resolve parameters: defaults -> ENV (if present) -> CLI (if provided) ===
# 1) defaults
$atr_stop       = 6.0
$atr_profit     = 3.0
$sma_filter     = 200
$rsi2_period    = 2
$rsi3_period    = 3
$oversold       = 20
$overbought     = 88
$breakout_entry = 36
$breakout_exit  = 40

# 2) ENV (apply only if key exists so it doesn't override defaults unless set)
$atr_stop       = ENV["ATR_STOP"].to_f       if ENV.key?("ATR_STOP")
$atr_profit     = ENV["ATR_PROFIT"].to_f     if ENV.key?("ATR_PROFIT")
$sma_filter     = ENV["SMA_FILTER"].to_i     if ENV.key?("SMA_FILTER")
$rsi2_period    = ENV["RSI2_PERIOD"].to_i    if ENV.key?("RSI2_PERIOD")
$rsi3_period    = ENV["RSI3_PERIOD"].to_i    if ENV.key?("RSI3_PERIOD")
$oversold       = ENV["OVERSOLD"].to_i       if ENV.key?("OVERSOLD")
$overbought     = ENV["OVERBOUGHT"].to_i     if ENV.key?("OVERBOUGHT")
$breakout_entry = ENV["BREAKOUT_ENTRY"].to_i if ENV.key?("BREAKOUT_ENTRY")
$breakout_exit  = ENV["BREAKOUT_EXIT"].to_i  if ENV.key?("BREAKOUT_EXIT")

# 3) CLI (wins last if user provided a flag)
$atr_stop       = options[:atr_stop]       if options[:atr_stop]
$atr_profit     = options[:atr_profit]     if options[:atr_profit]
$sma_filter     = options[:sma_filter]     if options[:sma_filter]
$rsi2_period    = options[:rsi2_period]    if options[:rsi2_period]
$rsi3_period    = options[:rsi3_period]    if options[:rsi3_period]
$oversold       = options[:oversold]       if options[:oversold]
$overbought     = options[:overbought]     if options[:overbought]
$breakout_entry = options[:breakout_entry] if options[:breakout_entry]
$breakout_exit  = options[:breakout_exit]  if options[:breakout_exit]

# ================================================

puts "=== ACTIVE CONFIGURATION ==="
puts "ATR Stop Multiplier   = #{$atr_stop}"
puts "ATR Profit Multiplier = #{$atr_profit}"
puts "SMA Filter Length     = #{$sma_filter == 0 ? "OFF" : $sma_filter}"

puts "RSI2 Period           = #{$rsi2_period}, Oversold=#{$oversold}, Overbought=#{$overbought}"
puts "RSI3 Period           = #{$rsi3_period}, Oversold=#{$oversold}, Overbought=#{$overbought}"
puts "Breakout Entry Window = #{$breakout_entry}, Exit Window=#{$breakout_exit}"
puts "============================"

puts "\n🟢 MODE: #{options[:one_trade] ? 'ONE-TRADE (Strict Sequential)' : 'MULTI-TRADE (All Concurrent)'}"
puts "-------------------------------------------------------------"

abort("You must provide --symbols") unless options[:symbols]

# Pick the first CLI symbol and store it in an env var the finalizer reads.
first_sym = options[:symbols]&.first

# first_sym = first_sym.to_s.sub(/_GoogleFinance_AutoUpToDate\z/, '')

ENV["METRICS_SYMBOL"] = strip_suffix(first_sym || "TOTAL")

# ===============================
# RUN
# ===============================
Dir.mkdir(RESULTS_DIR) unless Dir.exist?(RESULTS_DIR)
$all_trades.clear
all_trades = $all_trades
$global_position = nil

def append_row_atomic!(path, row, header: nil)
  FileUtils.mkdir_p(File.dirname(path)) rescue nil
  mode = File.exist?(path) ? "a" : "w"
  File.open(path, mode) do |f|
    f.flock(File::LOCK_EX)
    begin
      if f.size == 0 && header
        f.write(CSV.generate_line(header))
      end
      f.write(CSV.generate_line(row))
      f.flush
      f.fsync rescue nil
    ensure
      f.flock(File::LOCK_UN)
    end
  end
end

def write_csv_atomic!(path)
  tmp = "#{path}.tmp-#{$$}"
  CSV.open(tmp, "w") { |csv| yield csv }
  File.open(tmp, File::RDWR, &:fsync) rescue nil
  FileUtils.mv(tmp, path)
  File.open(path, File::RDWR, &:fsync) rescue nil
end

def append_ranked_sweep_summary!(path, scored, run_syms:, run_id:)
  FileUtils.mkdir_p(File.dirname(path)) rescue nil

  need_header = !File.exist?(path) || File.size(path).to_i == 0
  header = %w[
    run_id run_symbols
    rank best symbols atr_stop atr_profit sma_filter rsi2_period rsi3_period rsi_os rsi_ob breakout_entry breakout_exit
    trades win_rate pf cagr total_return final_equity max_dd score
    from to years
  ]

  CSV.open(path, "a") do |csv|
    csv << header if need_header
    scored.each_with_index do |h, i|
      csv << [
        run_id, run_syms,
        i+1, (i == 0 ? "YES" : ""),
        h[:symbols],
        h[:atr_stop], h[:atr_profit], h[:sma_filter], h[:rsi2_period], h[:rsi3_period], h[:rsi_os], h[:rsi_ob], h[:breakout_entry], h[:breakout_exit],
        h[:trades], h[:win_rate], h[:pf], h[:cagr], h[:total_return], h[:final_equity], h[:max_dd],
        h[:score].round(4),
        h[:from], h[:to], h[:years]
      ]
    end
  end
end

def log_sweep_row!(
  status:, symbols:, stop:, profit:, sma:, rsi2:, rsi3:, rsi_os:, rsi_ob:, be:, bx:,
  trades: nil, win: nil, pf: nil, cagr: nil, total_return: nil, final_equity: nil, maxdd: nil, score: nil,
  from: nil, to: nil, years: nil
)
  header = %w[
    ts status symbols stop profit sma rsi2 rsi3 rsi_os rsi_ob be bx
    trades win pf cagr total_return final_equity maxdd score
    from to years
  ]
  row = [
    Time.now.utc.iso8601, status, Array(symbols).join(","), stop, profit, sma, rsi2, rsi3, rsi_os, rsi_ob, be, bx,
    trades, win, pf, cagr, total_return, final_equity, maxdd, score,
    from, to, years
  ]
  append_sweep_live!(row, header)
end

if options[:sweep]


# --- Enable lightweight I/O in sweep mode ---
ENV["FAST_SWEEP"] = "1"
$FAST_SWEEP = true

# --- Resume support: build a set of already-tested combos ---
def norm_f(x) # canonicalize floats (avoid 2 vs 2.0 mismatches)
  ("%.4f" % x.to_f)
end
def norm_i(x) x.to_i.to_s end

# --- Resume support: only skip combos that have a DONE row
done    = {}
running = {}
already = {}

if File.exist?(SWEEP_LIVE)
  CSV.foreach(SWEEP_LIVE, headers: true) do |r|
    status = r["status"].to_s.upcase
    key = [
      norm_f(r["stop"]), norm_f(r["profit"]), norm_i(r["sma"]), norm_i(r["rsi2"]), norm_i(r["rsi3"]),
      norm_i(r["rsi_os"]), norm_i(r["rsi_ob"]),
      norm_i(r["be"]), norm_i(r["bx"]),
      r["symbols"].to_s.strip
    ].join("|")

    if status == "DONE"
      done[key] = true
    elsif status == "RUNNING"
      running[key] = true
    end
  end

  already = done.merge(running) # not used for skipping; just FYI
  puts "[SWEEP] Resuming — skip #{done.size} DONE combos; re-run #{running.size} incomplete combos."
else
  puts "[SWEEP] Fresh run."
end

# Helper to make the same key before each test
make_key = ->(stop_mult, profit_mult, sma_len, rsi2, rsi3, rsi_os, rsi_ob, be, bx, syms) {
  [
    norm_f(stop_mult), norm_f(profit_mult), norm_i(sma_len), norm_i(rsi2),
    norm_i(rsi3),
    norm_i(rsi_os), norm_i(rsi_ob),
    norm_i(be), norm_i(bx),
    Array(syms).map(&:to_s).sort.join(",")  # ← sort for stability
  ].join("|")
}

def append_sweep_live!(row, header)
  append_row_atomic!(SWEEP_LIVE, row, header: header)
rescue => e
  warn "[SWEEP_LIVE_ERR] #{e.class}: #{e.message}"
end

def write_best_so_far!(hash)
  write_csv_atomic!(SWEEP_BEST) do |csv|
    csv << hash.keys
    csv << hash.values
  end
rescue => e
  warn "[SWEEP_BEST_ERR] #{e.class}: #{e.message}"
end

# Save a last snapshot if interrupted (Ctrl+C / kill)
%w[INT TERM].each do |sig|
  trap(sig) do
    puts "\n[SWEEP] Received #{sig}. Flushing progress…"

    # Build a minimal “so far” summary ranked by score from DONE rows
    begin
      rows = File.exist?(SWEEP_LIVE) ? CSV.read(SWEEP_LIVE, headers: true) : []
      done_rows = rows.select { |r| r["status"].to_s.upcase == "DONE" }
      ranked = done_rows.sort_by { |r| -r["score"].to_f }

      write_csv_atomic!(File.join(RESULTS_DIR, "sweep_summary_so_far.csv")) do |csv|
        csv << %w[
          rank symbols stop profit sma rsi2 rsi3 rsi_os rsi_ob be bx
          trades win pf cagr total_return final_equity maxdd score
          from to years                              

        ]
        ranked.each_with_index do |r, i|
        csv << [
          i+1, r["symbols"], r["stop"], r["profit"], r["sma"], r["rsi2"], r["rsi3"], r["rsi_os"], r["rsi_ob"],
          r["be"], r["bx"], r["trades"], r["win"], r["pf"], r["cagr"], r["total_return"],
          r["final_equity"], r["maxdd"], r["score"],
          r["from"], r["to"], r["years"]           
        ]
        end
      end
    rescue => e
      warn "[SWEEP_TRAP_SUMMARY_ERR] #{e.class}: #{e.message}"
    end

    puts "   Saved:"
    puts "   - #{SWEEP_LIVE}"
    puts "   - #{SWEEP_BEST}"
    puts "   - #{File.join(RESULTS_DIR, 'sweep_summary_so_far.csv')}"
    exit
  end
end

  # ===============================
  # PARAMETER SWEEP MODE
  # ===============================



sma_filter_values     = [0, 100, 200]

rsi2_period_values = [1, 2, 3, 4, 5]
rsi3_period_values = [1, 2, 3, 4, 5]



# Entry Settings: Deep Crypto Liquidation/Cascading Margin Calls
rsi_oversold_values = (0..35).to_a

# Exit Settings: The Parabolic Ride
rsi_overbought_values = (65..100).to_a

# Trend Logic: Breakout values adjusted for high-beta velocity
breakout_exit_values  = [2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30]
breakout_entry_values = [2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30]

# Protection
atr_stop_values       = [6.0]

# Profit Taking
#atr_profit_values     = [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
atr_profit_values     = [1.5, 2.0, 2.5, 3.0]

  best_config = nil   #  keep track of best config
sweep_results = []

 # atr_stop_values.each do |stop_mult|
  #  atr_profit_values.each do |profit_mult|
   #   sma_filter_values.each do |sma_len|
    #    rsi_oversold_values.each do |rsi_os|
     #     rsi_overbought_values.each do |rsi_ob|
      #      breakout_entry_values.each do |be|
       #       breakout_exit_values.each do |bx|

# Run 1,000 random parameter combinations (or set to whatever number you want)
1000.times do |i|
  stop_mult   = atr_stop_values.sample
  profit_mult = atr_profit_values.sample
  sma_len     = sma_filter_values.sample
  rsi_os      = rsi_oversold_values.sample
  rsi_ob      = rsi_overbought_values.sample
  be          = breakout_entry_values.sample
  bx          = breakout_exit_values.sample


  rsi2_period = rsi2_period_values.sample
  rsi3_period = rsi3_period_values.sample


                puts "\n=== Testing Config ==="
                puts "ATR_STOP_MULT   = #{stop_mult}"
                puts "ATR_PROFIT_MULT = #{profit_mult}"
                puts "SMA_FILTER      = #{sma_len == 0 ? "OFF" : sma_len}"
                puts "RSI2 Period     = #{rsi2_period}"
                puts "RSI3 Period     = #{rsi3_period}"
                puts "RSI Oversold    = #{rsi_os}, Overbought = #{rsi_ob}"
                puts "Breakout Entry  = #{be}, Exit = #{bx}"
                puts "======================="

# override params on a copy to avoid side-effects
cfg = options.dup
cfg[:atr_stop]       = stop_mult
cfg[:atr_profit]     = profit_mult
cfg[:sma_filter]     = sma_len
cfg[:rsi2_period]    = rsi2_period
cfg[:rsi3_period]    = rsi3_period
cfg[:oversold]       = rsi_os
cfg[:overbought]     = rsi_ob
cfg[:breakout_entry] = be
cfg[:breakout_exit]  = bx

             $all_trades.clear
all_trades = $all_trades
$global_position = nil  #  reset once for this sweep config

# sync globals that rsi2_cfg/rsi3_cfg/breakout_* read
$rsi2_period    = cfg[:rsi2_period] || 2
$rsi3_period    = cfg[:rsi3_period] || 3
$oversold       = cfg[:oversold]
$overbought     = cfg[:overbought]
$breakout_entry = cfg[:breakout_entry]
$breakout_exit  = cfg[:breakout_exit]

key = make_key.call(stop_mult, profit_mult, sma_len, rsi2_period, rsi3_period, rsi_os, rsi_ob, be, bx, options[:symbols])

# Only skip completed (DONE) combos; re-run any RUNNING ones
if done[key]
  puts "[SWEEP] Skipping DONE combo #{key}"
  next
end

# Mark RUNNING immediately for crash-safe resumes
running[key] = true
cli_from = (cfg[:from] || options[:from])
cli_to   = (cfg[:to]   || options[:to])

log_sweep_row!(
  status: "RUNNING", symbols: options[:symbols],
  stop: stop_mult, profit: profit_mult, sma: sma_len, 
  rsi2: rsi2_period,
  rsi3: rsi3_period,
  rsi_os: rsi_os, rsi_ob: rsi_ob, be: be, bx: bx,
  from: cli_from&.iso8601, to: cli_to&.iso8601
)

options[:symbols].each do |sym|

$global_active_slots = 0 
  $active_tickers = []

  puts "[RUNNING] #{sym}..."
  trades, _, start_date, end_date = backtest(sym, options: cfg)
  stats = compute_stats(trades, start_date, end_date)
                  puts "[RESULT] #{sym} | Trades=#{stats[:trades]} | PF=#{stats[:pf].round(2)} | CAGR=#{stats[:cagr].round(2)}%"
               
               
sweep_signals = _

puts "=== LAST 3 SIGNALS: #{sym} ==="

if sweep_signals.nil? || sweep_signals.empty?
  puts "No signals."
else
  sweep_signals.last(3).each do |signal|
    puts [
      signal[:date],
      signal[:symbol],
      signal[:signal],
      signal[:close]
    ].join(",")
  end

  latest_signal = sweep_signals.last

  signal_date = Date.parse(latest_signal[:date].to_s) rescue nil
  final_date  = Date.parse(end_date.to_s) rescue nil

  if latest_signal[:signal].to_s.upcase == "BUY" &&
     signal_date == final_date
    puts ">>> TOMORROW ORDER: BUY #{sym} AT NEXT OPEN"
  else
    puts ">>> TOMORROW ORDER: NONE"
  end
end

puts "========================================"


                  all_trades.concat(trades)

                end # symbols.each

                if all_trades.any?
                  suffix = "#{stop_mult}x#{profit_mult}_sma#{sma_len}_rsi#{rsi_os}-#{rsi_ob}_bo#{be}-#{bx}"

                  # === Yearly breakdown ===
capital = 1000.0
yearly = {}

# Show the very first trade across all symbols
puts "First trade: #{all_trades.first[:symbol]} on #{all_trades.first[:entry_date]}" if all_trades.any?

all_trades.sort_by { |t| t[:entry_date] }.each do |t|
  year = t[:exit_date][0,4].to_i   # return counts for the year it closed
  capital *= (1 + t[:pct_return].to_f / 100.0)
  yearly[year] ||= { start: (yearly[year-1] ? yearly[year-1][:end] : 1000.0), end: capital, trades: 0 }
  yearly[year][:end] = capital
  yearly[year][:trades] += 1
end


end 
if all_trades.any?
  overall_start = all_trades.first[:entry_date]
  overall_end   = all_trades.last[:exit_date]
  stats = compute_stats(all_trades, overall_start, overall_end)

  # --- Print CONFIG SUMMARY ---
  final_equity = all_trades.inject(1000.0) { |eq, t| eq * (1 + t[:pct_return].to_f / 100) }
  total_return = ((final_equity - 1000.0) / 1000.0 * 100).round(2)

# --- Calculate MaxDD, Sharpe, Sortino ---
equity_curve = [1000.0]
all_trades.sort_by { |t| t[:entry_date] }.each do |t|
  equity_curve << equity_curve[-1] * (1 + t[:pct_return].to_f / 100.0)
end

peak   = equity_curve.first
max_dd = 0.0
equity_curve.each do |val|
  peak = [peak, val].max
  dd   = (peak - val) / peak * 100.0
  max_dd = [max_dd, dd].max
end

sharpe  = 0  # placeholder or real calc
sortino = 0  # placeholder or real calc

# --- Save config stats ---
# ---- pick a winner on the fly (composite score) ----
score = (stats[:pf].to_f.clamp(0, 3.0) / 3.0) * 0.55 +
        ((stats[:win_rate].to_f / 100.0).clamp(0, 1.0)) * 0.30 +
        ((stats[:cagr].to_f / 100.0)) * 0.15 -
        (max_dd.to_f / 100.0) * 0.05  # small penalty for drawdown

        overall_start = all_trades.first[:entry_date]
overall_end   = all_trades.last[:exit_date]
years_span    = ((Date.parse(overall_end) - Date.parse(overall_start)) / 365.0).round(2)

sweep_results << {
  symbols: options[:symbols].join(","),   
  atr_stop: stop_mult, atr_profit: profit_mult, sma_filter: sma_len, rsi2_period: rsi2_period,
rsi3_period: rsi3_period,
  rsi_os: rsi_os, rsi_ob: rsi_ob, breakout_entry: be, breakout_exit: bx,
  trades: stats[:trades], win_rate: stats[:win_rate].round(2), pf: stats[:pf].round(2), cagr: stats[:cagr].round(2),
  total_return: total_return, final_equity: final_equity.round(2), max_dd: max_dd.round(2),
  from: overall_start, to: overall_end, years: years_span,
  score: score # (raw; you can round later)
}

candidate = {
  stop: stop_mult, profit: profit_mult, sma: sma_len, 
  rsi2_period: rsi2_period,
  rsi3_period: rsi3_period,
  rsi_os: rsi_os, rsi_ob: rsi_ob, be: be, bx: bx,
  trades: stats[:trades], pf: stats[:pf], win: stats[:win_rate],
  cagr: stats[:cagr], max_dd: max_dd, score: score,
  from: overall_start, to: overall_end, years: years_span
}

# --- Persist this combo immediately (per-combo live log) ---
cli_from = (cfg[:from] || options[:from])
cli_to   = (cfg[:to]   || options[:to])
span_years = if cli_from && cli_to
  ((cli_to - cli_from) / 365.0).round(2)
else
  years_span # keep your computed span if CLI dates weren’t set
end

log_sweep_row!(
  status: "DONE", symbols: options[:symbols],
  stop: stop_mult, profit: profit_mult, sma: sma_len, 
  rsi2: rsi2_period,
  rsi3: rsi3_period, rsi_os: rsi_os, rsi_ob: rsi_ob, be: be, bx: bx,
  trades: stats[:trades], win: stats[:win_rate].round(2), pf: stats[:pf].round(2), cagr: stats[:cagr].round(2),
  total_return: total_return, final_equity: final_equity.round(2), maxdd: max_dd.round(2), score: score.round(4),
  from: cli_from&.iso8601, to: cli_to&.iso8601, years: span_years
)
running.delete(key)
done[key] = true

# --- Update best-so-far file immediately if improved ---
if best_config.nil? || candidate[:score] > best_config[:score]
  best_config = candidate
  write_best_so_far!({
  symbols: options[:symbols].join(","),
  atr_stop: stop_mult, atr_profit: profit_mult, sma: sma_len, rsi2_period: rsi2_period,
rsi3_period: rsi3_period,
  rsi_os: rsi_os, rsi_ob: rsi_ob, breakout_entry: be, breakout_exit: bx,
  trades: stats[:trades], win_rate: stats[:win_rate].round(2),
  pf: stats[:pf].round(2), cagr: stats[:cagr].round(2),
  total_return: total_return, final_equity: final_equity.round(2),
  max_dd: max_dd.round(2), score: score.round(4),
  from: overall_start, to: overall_end, years: years_span
})
end

best_config = candidate if best_config.nil? || candidate[:score] > best_config[:score]

#puts ">>> CONFIG SUMMARY: CAGR=#{stats[:cagr].round(2)}% | PF=#{stats[:pf].round(2)} " \
#     "| MaxDD=#{max_dd.round(2)}% | Sharpe=#{sharpe} | Sortino=#{sortino} " \
#     "| TotalReturn=#{total_return}% | FinalEquity=$#{final_equity.round(2)}"

  # Calculate MaxDD, Sharpe, Sortino like in normal run
  equity_curve = [1000.0]
  all_trades.sort_by { |t| t[:entry_date] }.each do |t|
    equity_curve << equity_curve[-1] * (1 + t[:pct_return].to_f / 100.0)
  end
  peak, max_dd, dd_list = equity_curve.first, 0.0, []
  equity_curve.each do |val|
    peak = [peak, val].max
    dd = (peak - val) / peak * 100.0
    max_dd = [max_dd, dd].max
    dd_list << dd
  end
  sharpe  = 0 # keep simple or copy your calc
  sortino = 0 # keep simple or copy your calc

  puts ">>> CONFIG SUMMARY: CAGR=#{stats[:cagr].round(2)}% | PF=#{stats[:pf].round(2)} " \
       "| MaxDD=#{max_dd.round(2)}% | Sharpe=#{sharpe} | Sortino=#{sortino} " \
     "| WinRate=#{stats[:win_rate].round(2)}% | " \
       "| TotalReturn=#{total_return}% | FinalEquity=$#{final_equity.round(2)}"

  # --- Yearly breakdown ---
  capital = 1000.0
  yearly = {}
all_trades.sort_by { |t| t[:entry_date] }.each do |t|
    year = t[:exit_date][0,4].to_i
    capital *= (1 + t[:pct_return].to_f / 100.0)
    yearly[year] ||= { start: (yearly[year-1] ? yearly[year-1][:end] : 1000.0), end: capital, trades: 0 }
    yearly[year][:end] = capital
    yearly[year][:trades] += 1
  end

  puts "Yearly Breakdown ----------------------"
  yearly.keys.sort.each do |y|
    start_balance = yearly[y][:start]
    end_balance   = yearly[y][:end]
    pct_return    = ((end_balance - start_balance) / start_balance * 100).round(2)
    puts "#{y}: Trades=#{yearly[y][:trades]} | Start=$#{start_balance.round(2)} | End=$#{end_balance.round(2)} | Return=#{pct_return}%"
  end
  puts "---------------------------------------"
end
      #        end # breakout_exit_values.each
       #     end # breakout_entry_values.each
     #     end # rsi_overbought_values.each
    #    end # rsi_oversold_values.each
   #   end # sma_filter_values.each
  #  end # atr_profit_values.each
 # end # atr_stop_values.each
 end # end of parameter sweep loop
# 🚀 Rank results, print winner + top 5, and save ranked CSV

scored = sweep_results.map do |h|
  # if you want to recompute score, you can; otherwise keep h[:score]
  h
end

scored.sort_by! { |h| -h[:score] }
winner = scored.first
if winner
  puts "\n🏆 WINNER"
  puts "   ATR_STOP=#{winner[:atr_stop]}  ATR_PROFIT=#{winner[:atr_profit]}  SMA=#{winner[:sma_filter]}"
  puts "   RSI OS=#{winner[:rsi_os]}  OB=#{winner[:rsi_ob]}  BO Entry=#{winner[:breakout_entry]} Exit=#{winner[:breakout_exit]}"
  puts "   Trades=#{winner[:trades]}  PF=#{winner[:pf].round(2)}  Win=#{winner[:win_rate].round(1)}%  CAGR=#{winner[:cagr].round(2)}%  MaxDD=#{winner[:max_dd].round(2)}%"
end

puts "\n🔝 TOP 5"
scored.first(5).each_with_index do |h, i|
  puts "%2d) score=%.4f | PF=%.2f Win=%.1f%% CAGR=%.2f%% MaxDD=%.2f%% | "\
       "stop=%.2f profit=%.2f sma=%s rsi=%d-%d bo=%d-%d" %
       [i+1, h[:score], h[:pf], h[:win_rate], h[:cagr], h[:max_dd],
        h[:atr_stop], h[:atr_profit], h[:sma_filter], h[:rsi_os], h[:rsi_ob], h[:breakout_entry], h[:breakout_exit]]
end

run_id   = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
run_syms = Array(options[:symbols]).join(",")

summary_path = File.join(RESULTS_DIR, "sweep_summary.csv")
append_ranked_sweep_summary!(summary_path, scored, run_syms: run_syms, run_id: run_id)

puts "[DONE] Appended #{scored.size} rows to #{summary_path} (run_id=#{run_id}, symbols=#{run_syms})"

  if best_config
    puts "\n==============================="
    puts "🏆 BEST CONFIG FOUND (by composite score)"
    puts "ATR_STOP=#{best_config[:stop]} | ATR_PROFIT=#{best_config[:profit]} | SMA=#{best_config[:sma]}"
    puts "RSI OS=#{best_config[:rsi_os]} OB=#{best_config[:rsi_ob]} | BO Entry=#{best_config[:be]} Exit=#{best_config[:bx]}"
    puts "Trades=#{best_config[:trades]} | PF=#{best_config[:pf]} | CAGR=#{best_config[:cagr]}%"
    puts "==============================="
  end

metrics_path = ENV["METRICS_CSV"]
if metrics_path
  # puts "[TUNE EXPORT] Writing metrics before exit (FAST_TUNE active)"
  begin
    latest_summary = Dir.glob(File.join(RESULTS_DIR, "hybrid_v3_summary.csv"))
                        .max_by { |f| File.mtime(f) rescue Time.at(0) }

    if latest_summary && File.exist?(latest_summary)
      rows = CSV.read(latest_summary, headers: true)
      valid_row = rows.find { |r| (r["symbol"] || "").upcase != "TOTAL" && r["trades"].to_i > 0 }

      if valid_row
        # 🩵 Convert any Hash/Array values to safe strings before CSV writing
        valid_row = valid_row.to_h.transform_values do |v|
          case v
          when Hash then v.values.first.to_s
          when Array then v.first.to_s
          else v.to_s
          end
        end

        FileUtils.mkdir_p(File.dirname(metrics_path)) rescue nil

        CSV.open(metrics_path, "w") do |csv|
          csv << %w[symbol trades win_rate pf cagr max_drawdown]
          csv << [
            valid_row["symbol"],
            valid_row["trades"],
            valid_row["win_rate"],
            valid_row["pf"],
            valid_row["cagr"],
            valid_row["max_drawdown"]
          ]
        end

        # puts "[TUNE EXPORT] ✅ metrics written before exit"
      else
        puts "[TUNE EXPORT] ⚠️ No valid row found"
      end
    else
      puts "[TUNE EXPORT] ⚠️ Summary missing before exit"
    end 
  rescue => e
    warn "[TUNE_EXPORT_ERR] #{e.class}: #{e.message}"
  end
end

# ✅ In sweep mode, write a metrics row immediately from the best result
metrics_path = ENV["METRICS_CSV"]
if metrics_path && !scored.empty?
  best = scored.first
  FileUtils.mkdir_p(File.dirname(metrics_path)) rescue nil
  CSV.open(metrics_path, "w") do |csv|
    csv << %w[symbol trades win_rate pf cagr max_drawdown]
    # choose a label you like; "WINNER" is fine
    csv << [
      "WINNER",
      best[:trades],
      best[:win_rate],
      best[:pf],
      best[:cagr],
      best[:max_dd]
    ]
  end
  ENV["METRICS_CSV_ALREADY_WRITTEN"] = "1"
  puts "[BOT_METRICS] sweep metrics written → #{metrics_path}"
end

# =====================================================
#  FINAL REAL METRICS EXPORT FOR TUNER
# =====================================================
begin
  metrics_path = ENV["METRICS_CSV"]   #  keep this line
  if metrics_path                     #  change condition to this
    latest_summary = Dir.glob(File.join(RESULTS_DIR, "hybrid_v3_summary.csv"))
                         .max_by { |f| File.mtime(f) rescue Time.at(0) }

    if latest_summary && File.exist?(latest_summary)
      rows = CSV.read(latest_summary, headers: true)
      valid_row = rows.find { |r| (r["symbol"] || "").upcase != "TOTAL" && 
                                  r["trades"] && r["trades"].to_i > 0 }

      if valid_row
        FileUtils.mkdir_p(File.dirname(metrics_path)) rescue nil
        CSV.open(metrics_path, "w") do |csv|
          csv << %w[symbol trades win_rate pf cagr max_drawdown]
          csv << [
            valid_row["symbol"],
            valid_row["trades"],
            valid_row["win_rate"],
            valid_row["pf"],
            valid_row["cagr"],
            valid_row["max_drawdown"]
          ]
        end
     puts "[BOT_METRICS] ✅ metrics copied → #{metrics_path}"
ENV["METRICS_CSV_ALREADY_WRITTEN"] = "1"   # ← add this

# --- Stronger variant: actively verify the tuner can read the file ---
5.times do |i|
  sleep 2
  size = File.size?(metrics_path)
  mtime = File.mtime(metrics_path) rescue nil
  puts "[BOT_METRICS] Check #{i+1}/5 → size=#{size || 0} bytes | mtime=#{mtime}"
end

if File.size?(metrics_path).to_i > 60
  puts "[BOT_METRICS]  confirmed metrics file is fully written and visible"
else
  puts "[BOT_METRICS] ⚠️ file may still be small (tuner might need a few more sec)"
end
      else
        warn "[BOT_METRICS] ⚠️ no valid data found in #{latest_summary}"
      end
    else
      warn "[BOT_METRICS] ⚠️ summary file missing"
    end
  else
    warn "[BOT_METRICS] ⚠️ ENV['METRICS_CSV'] not set"
  end
rescue => e
  warn "[BOT_METRICS_ERR] #{e.class}: #{e.message}"
end

# --- ensure metrics fully written before tuner reads ---
if ENV["METRICS_CSV"] && File.exist?(ENV["METRICS_CSV"])
  begin
    puts "[SYNC] Writing metrics summary → #{ENV['METRICS_CSV']}"
    sleep 1.5  # ✅ give the OS buffer a chance to flush
    puts "[SYNC] ✅ Metrics ready"
  rescue => e
    warn "[SYNC_ERR] #{e.class}: #{e.message}"
  end
end

  exit  # 👈 prevents running the normal block
end   # if options[:sweep]

# =====================================================
# 🩵 FINAL TUNER SYNC FALLBACK (if summary not found)
# =====================================================
begin
  metrics_path = ENV["METRICS_CSV"]
  if metrics_path && File.exist?(metrics_path)
    lines = File.readlines(metrics_path)
    if lines.size <= 2
trades       = $all_trades.size rescue 0
pf           = $profit_factor  rescue 0
win_rate_val = $win_rate       rescue 0
cagr_val     = $real_cagr      rescue 0
maxdd_val    = $max_dd         rescue 0

      CSV.open(metrics_path, "w") do |csv|
        csv << %w[symbol trades win_rate pf cagr max_drawdown]
        csv << ["FALLBACK", trades, win_rate_val, pf, cagr_val, maxdd_val]
      end
      puts "[BOT_METRICS] 🩵 fallback metrics written for tuner"
    end
  end
rescue => e
  warn "[BOT_METRICS] ⚠️ fallback metrics failed: #{e.message}"
end

# ===============================
# COLLECT TRADES + SIGNALS PER SYMBOL
# ===============================
all_trades  = $all_trades   # or just delete this line if 'all_trades' is already the alias
all_trades.clear
all_signals = []

options[:symbols].each do |sym|
  puts "[RUNNING] #{sym} with Hybrid v3 Strategy..."

  # build per-symbol opts (same logic as main loop)
sym_opts = options.dup

sym_base = strip_suffix(sym)

tech_symbols = %w[
  
  TEST234_GoogleFinance_AutoUpToDate
  Test123_GoogleFinance_AutoUpToDate
]

# ✅ Only apply hardcoded presets if NOT tuning or sweeping
unless ENV["FAST_SWEEP"] == "1" || ENV["FAST_TUNE"] == "1"
  if tech_symbols.any? { |t| sym.include?(t) }
  sym_opts[:atr_stop]       = 6.0
  sym_opts[:atr_profit]     = 3.0
  sym_opts[:sma_filter]     = 200
  sym_opts[:rsi2_period]    = 2
  sym_opts[:rsi3_period]    = 3
  sym_opts[:oversold]       = 20
  sym_opts[:overbought]     = 88
  sym_opts[:breakout_entry] = 36
  sym_opts[:breakout_exit]  = 40
  else
  sym_opts[:atr_stop]       = 6.0
  sym_opts[:atr_profit]     = 3.0
  sym_opts[:sma_filter]     = 200
  sym_opts[:rsi2_period]    = 2
  sym_opts[:rsi3_period]    = 3
  sym_opts[:oversold]       = 20
  sym_opts[:overbought]     = 88
  sym_opts[:breakout_entry] = 36
  sym_opts[:breakout_exit]  = 40
  end
end

case
  
when sym.include?("NVDA_GoogleFinance_AutoUpToDate")
  sym_opts[:atr_stop]       = 6.0
  sym_opts[:atr_profit]     = 3.0
  sym_opts[:sma_filter]     = 0
  sym_opts[:rsi2_period]    = 3
  sym_opts[:rsi3_period]    = 2
  sym_opts[:oversold]       = 18
  sym_opts[:overbought]     = 84
  sym_opts[:breakout_entry] = 8
  sym_opts[:breakout_exit]  = 14

  when sym.include?("DELL_GoogleFinance_AutoUpToDate")
  sym_opts[:atr_stop]       = 6.0
  sym_opts[:atr_profit]     = 3.0
  sym_opts[:sma_filter]     = 200
  sym_opts[:rsi2_period]    = 2
  sym_opts[:rsi3_period]    = 3
  sym_opts[:oversold]       = 20
  sym_opts[:overbought]     = 88
  sym_opts[:breakout_entry] = 36
  sym_opts[:breakout_exit]  = 40


end

# --- CMD overrides ---# --- CMD overrides ---
sym_opts[:rsi2_period]    = options[:rsi2_period] if options[:rsi2_period]
sym_opts[:rsi3_period]    = options[:rsi3_period] if options[:rsi3_period]
sym_opts[:oversold]       = options[:oversold] if options[:oversold]
sym_opts[:overbought]     = options[:overbought] if options[:overbought]
sym_opts[:breakout_entry] = options[:breakout_entry] if options[:breakout_entry]
sym_opts[:breakout_exit]  = options[:breakout_exit] if options[:breakout_exit]
sym_opts[:sma_filter]     = options[:sma_filter] if options[:sma_filter]
sym_opts[:atr_stop]       = options[:atr_stop] if options[:atr_stop]
sym_opts[:atr_profit]     = options[:atr_profit] if options[:atr_profit]

# sync globals that rsi2_cfg/rsi3_cfg/breakout_* read
$rsi2_period    = sym_opts[:rsi2_period]
$rsi3_period    = sym_opts[:rsi3_period]
$oversold       = sym_opts[:oversold]
$overbought     = sym_opts[:overbought]
$breakout_entry = sym_opts[:breakout_entry]
$breakout_exit  = sym_opts[:breakout_exit]

# use sym_opts for this symbol
trades, per_signals, start_date, end_date = backtest(sym, options: sym_opts)
all_trades.concat(trades)
all_signals.concat(per_signals)
end

multi_combined_path = File.join(RESULTS_DIR, "hybrid_v3_all_multi_signals.csv")

# 🧹 Clean up old combined multi-signal file before rewriting
if File.exist?(multi_combined_path)
  File.delete(multi_combined_path)
  puts "🧹 Deleted old multi-signal combined file."
end

# === Combine and SORT all MULTI signal files (full BUY/SELL history) ===
multi_combined_path = File.join(RESULTS_DIR, "hybrid_v3_all_multi_signals.csv")
multi_files = options[:symbols].map { |sym| File.join(RESULTS_DIR, "#{sym}_multi_signals.csv") }.select { |f| File.exist?(f) }

all_multi_signals = []

multi_files.each do |file|
  CSV.foreach(file, headers: true) do |row|
    all_multi_signals << {
      date: row['date'],
      symbol: row['symbol'],
      signal: row['signal'],
      close: row['close']
    }
  end
end

# ✅ Sort by date first, then symbol for same-day signals
all_multi_signals.sort_by! do |s|
  date_obj = begin
    Date.parse(s[:date])
  rescue
    Date.new(0)
  end
  [date_obj, s[:symbol]]
end

multi_combined_path = File.join(RESULTS_DIR, "hybrid_v3_all_multi_signals.csv")
File.delete(multi_combined_path) if File.exist?(multi_combined_path)

CSV.open(multi_combined_path, "w") do |csv|
  csv << %w[date symbol signal close]
  all_multi_signals.each do |s|
    csv << [s[:date], s[:symbol], s[:signal], s[:close]]
  end
end

puts "[SAVED] Combined & sorted multi-signal file → #{multi_combined_path} (#{all_multi_signals.size} total signals)"

# === Deduplicate the combined multi-signal file (remove duplicates) ===
seen = Set.new
deduped = []

CSV.foreach(multi_combined_path, headers: true) do |row|
  key = [row['date'], row['symbol'], row['signal'], row['close']].join('|')
  next if seen.include?(key)
  seen.add(key)
  deduped << row
end

CSV.open(multi_combined_path, "w") do |csv|
  csv << %w[date symbol signal close]
  deduped.each { |r| csv << r }
end

puts "✅ Deduplicated #{deduped.size} unique rows in multi-signal file."

# === Print Latest Signal per Symbol (current state snapshot) ===
puts "\n=== Latest Signal per Symbol ==="
latest_signals = {}

options[:symbols].each do |sym|
  latest = all_signals.select { |s| s[:symbol] == sym }.max_by { |s| Date.parse(s[:date]) rescue Date.new(0) }
  if latest
    puts "#{sym.ljust(30)} | #{latest[:date]} → #{latest[:signal]} @ #{latest[:close]}"
    latest_signals[sym] = { 
      signal: latest[:signal],
      close: latest[:close],
        date: latest[:date],   # ⭐ ADD THIS LINE

      pf: 1.0,          # default placeholder
      win_rate: 0.0,
      cagr: 0.0
    }
  else
    puts "#{sym.ljust(30)} | No data"
  end
end

#build_tomorrow_orders_from_latest_signals!(TOMORROW_ORDERS_CSV, latest_signals)
#build_tomorrow_orders_from_all_signals!(TOMORROW_ORDERS_CSV, all_signals)
build_tomorrow_orders_like_backup!(TOMORROW_ORDERS_CSV, all_trades, latest_signals)

puts "================================="

# ===============================
# ENFORCE GLOBAL ONE-TRADE RULE (if requested)
# ===============================
all_trades.sort_by! { |t| Date.parse(t[:entry_date]) }

if options[:one_trade]
  puts "⚙️ Enforcing ONE-TRADE mode across all symbols..."
  filtered_trades = []
  last_exit = nil

  all_trades.each do |t|
    entry_d = Date.parse(t[:entry_date])
    exit_d  = Date.parse(t[:exit_date])

    if last_exit.nil? || entry_d > last_exit
      filtered_trades << t
      last_exit = exit_d
    else
      puts "⚠️ Skipped #{t[:symbol]} trade starting #{t[:entry_date]} (overlaps with previous)"
    end
  end

all_trades.replace(filtered_trades)   
else
  puts "⚙️ Running in MULTI-TRADE mode (no global trade restriction)."
end

# ✅ Optional: filter out old trades before 2013 (keeps modern era only)
#all_trades.select! { |t| Date.parse(t[:entry_date]) >= Date.new(2013, 1, 1) }
# === now that all_trades is FINAL, mark which signals were actually executed ===

def __to_date_or_nil(v)
  Date.parse(v.to_s) rescue nil
end

# we'll work on a copy so we can append missing sells
signals_for_export = all_signals.map(&:dup)

# index existing signals by [symbol, date] so we can see what's missing
have_signal = {}
signals_for_export.each do |s|
  d = __to_date_or_nil(s[:date])
  next unless d
  key = [s[:symbol], d]
  (have_signal[key] ||= []) << s[:signal].to_s.upcase
end

executed_buys  = []
executed_sells = []

all_trades.each do |t|
  sym    = t[:symbol]
  entryd = __to_date_or_nil(t[:entry_date])
  exitd  = __to_date_or_nil(t[:exit_date])

  executed_buys << { symbol: sym, date: entryd } if entryd

  if exitd
  
    executed_sells << { symbol: sym, date: exitd }
  end
end

combined_path = File.join(RESULTS_DIR, "hybrid_v3_all_signals.csv")

CSV.open(combined_path, "w") do |csv|
  csv << %w[date symbol signal close executed_entry executed_exit]

  signals_for_export
    .sort_by { |s| s[:date] }
    .each do |s|
      sig_d = __to_date_or_nil(s[:date])
      sig_d_str = sig_d ? sig_d.strftime("%Y-%m-%d") : s[:date].to_s

      entry_done = executed_buys.any? { |e|
        e[:symbol] == s[:symbol] &&
        e[:date]   == sig_d &&
        s[:signal].to_s.upcase == "BUY"
      } ? "done" : ""

      exit_done = executed_sells.any? { |e|
        e[:symbol] == s[:symbol] &&
        e[:date]   == sig_d &&
        s[:signal].to_s.upcase == "SELL"
      } ? "done" : ""

      csv << [sig_d_str, s[:symbol], s[:signal], s[:close], entry_done, exit_done]
    end
end

puts "[SAVED] Combined signal file → #{combined_path}"

# ===============================
# DEBUG / INFO
# ===============================
if all_trades.any?
  puts "Earliest trade: #{all_trades.first[:symbol]} from #{all_trades.first[:entry_date]} to #{all_trades.first[:exit_date]}"
  puts "Latest   trade: #{all_trades.last[:symbol]} from #{all_trades.last[:entry_date]} to #{all_trades.last[:exit_date]}"
end

# Save master file of combined trades
main_trades_path = File.join(RESULTS_DIR, "hybrid_v3_all_trades.csv")

CSV.open(main_trades_path, "w") do |csv|
  csv << %w[symbol entry_date exit_date entry exit pct_return]
  all_trades.each do |t|
    csv << [t[:symbol], t[:entry_date], t[:exit_date], t[:entry], t[:exit], t[:pct_return]]
  end
end
puts "[SAVED] #{main_trades_path}"
#rebuild_tomorrow_orders_from_trades!(TOMORROW_ORDERS_CSV, all_trades)
with_buys_path = File.join(RESULTS_DIR, "hybrid_v3_all_trades_With_Buys.csv")

begin
  # 1) clone the main all_trades file
  FileUtils.cp(main_trades_path, with_buys_path)
  puts "[CLONED] #{with_buys_path}"

  # 2) try to append the current OPEN BUY (if any) from the debug log
  log_dir  = File.join(BASE_DIR, "storage", "debug")
  log_path = File.join(log_dir, "hybrid_v3_log.txt")

  if File.exist?(log_path)
    open_positions = {}  # symbol => { entry_date, entry }

    IO.foreach(log_path) do |line|
      # We only care about lines that *start* with BUY or SELL and have "@ price"
      # e.g. "BUY NVDA_GoogleFinance_AutoUpToDate 2025-11-07T00:00:00Z @ 188.15"
      m = line.match(/\A(BUY|SELL)\s+(\S+)\s+(\S+)\s+@\s+([\d.]+)/)
      next unless m

      side, symbol, date_str, price_str = m.captures
      date  = Date.parse(date_str) rescue nil
      price = price_str.to_f
      next unless date

      if side == "BUY"
        open_positions[symbol] = {
          entry_date: date,
          entry:      price
        }
      else # SELL
        # when we see a SELL, that symbol is no longer open
        open_positions.delete(symbol)
      end
    end

    if open_positions.size == 1
      sym, pos = open_positions.first

      CSV.open(with_buys_path, "a") do |csv|
        # same columns as main file:
        # symbol, entry_date, exit_date, entry, exit, pct_return
        csv << [
          sym,
          pos[:entry_date].iso8601,
          nil,     # exit_date (unknown yet)
          pos[:entry],
          nil,     # exit price (unknown)
          nil      # pct_return (unknown)
        ]
      end

      puts "[WITH_BUYS] Appended open BUY: #{sym} #{pos[:entry_date]} @ #{pos[:entry]}"
    elsif open_positions.empty?
      puts "[WITH_BUYS] No open position found in log; cloned file has closed trades only."
    else
      warn "[WITH_BUYS] Multiple open positions found in log (#{open_positions.keys.join(', ')}); skipping BUY append."
    end
  else
    warn "[WITH_BUYS] Log file not found; cloned file has closed trades only."
  end

rescue => e
  warn "[COPY_ERR] Could not copy all_trades → With_Buys: #{e.class}: #{e.message}"
end

# ===============================
# YEARLY BREAKDOWN
# ===============================
start_capital = $start_equity
capital = start_capital
yearly = {}

all_trades.sort_by { |t| t[:entry_date] }.each do |t|
  year = t[:exit_date][0,4].to_i   # use exit year for return, but sort by entry
  capital *= (1 + t[:pct_return].to_f / 100.0)
  yearly[year] ||= { end: capital, trades: 0 }
  yearly[year][:end] = capital
  yearly[year][:trades] += 1
end

puts "\nYearly Breakdown (starting $#{start_capital}) ---------------------"
CSV.open("#{RESULTS_DIR}/hybrid_v3_yearly_breakdown.csv", "w") do |csv|
  csv << %w[year trades start_balance end_balance compounded_return non_comp_return]

  capital = start_capital
  prev_balance = start_capital

overall_start_year = all_trades.map { |t| t[:exit_date][0,4].to_i }.min
overall_end_year   = all_trades.map { |t| t[:exit_date][0,4].to_i }.max

  (overall_start_year..overall_end_year).each do |y|
    trades_for_year = all_trades.select { |t| t[:exit_date][0,4].to_i == y }
    start_balance = prev_balance

    trades_for_year.each do |t|
      capital *= (1 + t[:pct_return].to_f / 100.0)
    end

    end_balance = capital
    compounded  = ((end_balance - start_balance) / start_balance * 100).round(2)
    non_comp    = trades_for_year.sum { |t| t[:pct_return] }.round(2)

    puts "#{y}: Trades=#{trades_for_year.size} | Start=$#{start_balance.round(2)} | End=$#{end_balance.round(2)} | " \
         "Compounded=#{compounded}% | Non-Comp=#{non_comp}%"

    csv << [y, trades_for_year.size, start_balance.round(2), end_balance.round(2), compounded, non_comp]

    prev_balance = end_balance
  end
end

# === Yearly (Current fills) adjusted for fees/slippage via knobs ===
cur_adj_path = File.join(RESULTS_DIR, "hybrid_v3_yearly_breakdown_adjusted.csv")
equity       = $start_equity
yearlyB      = {}

all_trades.sort_by { |t| Date.parse(t[:entry_date]) rescue Date.new(1900,1,1) }.each do |t|
  y = t[:exit_date][0,4].to_i
  yearlyB[y] ||= { start: (yearlyB[y-1] ? yearlyB[y-1][:end] : $start_equity), end: nil, trades: 0 }

  gross_pct = t[:pct_return].to_f
  net_pct   = net_pct_after_costs(gross_pct, equity: equity)

  equity *= (1.0 + net_pct / 100.0)
  yearlyB[y][:end]    = equity
  yearlyB[y][:trades] += 1
end

CSV.open(cur_adj_path, "w") do |csv|
  csv << %w[year trades start_balance end_balance realistic_compounded_return]
prev = $start_equity
  yearlyB.keys.sort.each do |y|
    eb = yearlyB[y][:end] || prev
    cr = ((eb - prev) / prev * 100.0).round(2)
    csv << [y, yearlyB[y][:trades], prev.round(2), eb.round(2), cr]
    prev = eb
  end
end

# Print the adjusted baseline
print_yearly_table(cur_adj_path, title: "Yearly (Current, Fees+Slippage)")

# === Average, Median, Best, Worst, Volatility & Sharpe ===
returns = []
prev_balance = start_capital
yearly.keys.sort.each do |y|
  end_balance = yearly[y][:end]
  pct = ((end_balance - prev_balance) / prev_balance * 100)
  returns << pct
  prev_balance = end_balance
end

avg_return = (returns.sum / returns.size).round(2)
median_return = returns.sort[returns.size / 2].round(2)
best_year = returns.max.round(2)
worst_year = returns.min.round(2)

# Volatility (standard deviation of yearly returns)
mean = returns.sum / returns.size.to_f
variance = returns.map { |r| (r - mean) ** 2 }.sum / returns.size.to_f
volatility = Math.sqrt(variance).round(2)

# Sharpe ratio (assuming risk-free = 0)
sharpe = volatility.zero? ? 0 : (avg_return / volatility).round(2)

# Sortino ratio (downside deviation vs 0)
downside_returns = returns.select { |r| r < 0 }
if downside_returns.any?
  downside_variance = downside_returns.map { |r| r**2 }.sum / downside_returns.size.to_f
  downside_deviation = Math.sqrt(downside_variance)
  sortino = (avg_return / downside_deviation).round(2)
else
  sortino = 0
end

# === Win Rate & Profit Factor ===
wins   = all_trades.select { |t| t[:pct_return].to_f > 0 }
losses = all_trades.select { |t| t[:pct_return].to_f < 0 }
total  = all_trades.size

win_rate = total > 0 ? (wins.size.to_f / total * 100).round(2) : 0
gross_win  = wins.sum { |t| t[:pct_return].to_f }
gross_loss = losses.sum { |t| t[:pct_return].abs }
profit_factor = gross_loss.zero? ? "∞" : (gross_win / gross_loss).round(2)

$win_rate      = win_rate.to_f
$profit_factor = (profit_factor == "∞" ? 9_999.0 : profit_factor.to_f)

puts "-------------------------------------------------------------"
puts "Total Trades: #{total}"
puts "Winning Trades: #{wins.size}"
puts "Losing Trades: #{losses.size}"
puts "Win Rate: #{win_rate}%"
puts "Profit Factor: #{profit_factor}"
puts "-------------------------------------------------------------"
puts "Average Yearly Return: #{avg_return}%"
puts "Median Yearly Return: #{median_return}%"
puts "Best Year: #{best_year}%"
puts "Worst Year: #{worst_year}%"
puts "Volatility (Std Dev): #{volatility}%"
puts "Sharpe Ratio: #{sharpe}"
puts "Sortino Ratio: #{sortino}"

# --- Real CAGR & Final Equity (verified) ---
if all_trades.any?
  sorted = all_trades.sort_by { |t| Date.parse(t[:exit_date]) rescue Date.today }
  start_date  = Date.parse(sorted.first[:entry_date]) rescue Date.parse(sorted.first[:exit_date])
  end_date    = Date.parse(sorted.last[:exit_date]) rescue start_date
  total_years = [(end_date - start_date).to_f / 365.0, 0.01].max

  start_equity = $start_equity
  final_equity = sorted.inject(start_equity) { |eq, t| eq * (1 + t[:pct_return].to_f / 100.0) }
  real_cagr    = ((final_equity / start_equity) ** (1.0 / total_years) - 1) * 100.0
$real_cagr = real_cagr.to_f

  puts "-------------------------------------------------------------"
  puts "💰 Final Equity (#{start_date.year}→#{end_date.year}): $#{format('%.2f', final_equity)}"
  puts "📈 Verified CAGR: #{format('%.2f', real_cagr)}%"

  puts "-------------------------------------------------------------"
 # --- Real-world adjustment (fees + slippage) from the actual adjusted equity curve ---
# You already built a fees+slippage-adjusted equity curve into `yearlyB` and `equity`.
# `equity` here is the final adjusted balance.
realistic_equity = equity.to_f

# Recompute CAGR from adjusted equity curve span:
adj_start = Date.parse(overall_start) rescue start_date
adj_end   = Date.parse(overall_end)   rescue end_date
adj_years = [(adj_end - adj_start).to_f / 365.0, 0.01].max

realistic_cagr = ((realistic_equity / $start_equity) ** (1.0 / adj_years) - 1.0) * 100.0

puts "💸 Adjusted for fees & slippage:"
puts "   Trades: #{total} | Fees total (fixed) est: $#{($fee_fixed_usd*2*total).round(0)} | Percent fees (bps rt): #{$fee_rate_bps}"
puts "   Slippage (bps rt): #{$slip_bps}"
puts "   → Realistic CAGR ≈ #{format('%.2f', realistic_cagr)}%"
puts "   → Realistic Final Equity ≈ $#{format('%.0f', realistic_equity)}"
puts "-------------------------------------------------------------"
end

puts "-------------------------------------------------------------"
puts "[DONE] Yearly breakdown saved to #{RESULTS_DIR}/hybrid_v3_yearly_breakdown.csv"

# === Max Drawdown + Recovery Dates (fixed indices) ===
sorted = all_trades.sort_by { |t| Date.parse(t[:exit_date]) }
equity_curve = [1000.0]
sorted.each { |t| equity_curve << equity_curve[-1] * (1 + t[:pct_return].to_f / 100.0) }

start_date = Date.parse(sorted.first[:entry_date]) rescue Date.parse(sorted.first[:exit_date])
dates = [start_date] + sorted.map { |t| Date.parse(t[:exit_date]) }

peak_val = equity_curve[0]
peak_idx_current = 0
max_dd = 0.0
trough_idx = 0
peak_idx_at_dd = 0   # <-- the peak that CAUSED the worst DD

equity_curve.each_with_index do |v, i|
  if v > peak_val
    peak_val = v
    peak_idx_current = i
  end

  dd = (peak_val - v) / peak_val * 100.0
  if dd > max_dd
    max_dd = dd
    trough_idx = i
    peak_idx_at_dd = peak_idx_current  # freeze the peak at time of worst DD
  end
end

# Recovery from that particular peak
recovery_idx = nil
((trough_idx + 1)...equity_curve.size).each do |j|
  if equity_curve[j] >= equity_curve[peak_idx_at_dd] * 0.999
    recovery_idx = j
    break
  end
end

peak_date     = dates[peak_idx_at_dd]
trough_date   = dates[trough_idx]
recovery_date = recovery_idx ? dates[recovery_idx] : nil

days_peak_to_trough      = (trough_date - peak_date).to_i
days_trough_to_recovery  = recovery_date ? (recovery_date - trough_date).to_i : nil
months_trough_to_recover = days_trough_to_recovery ? (days_trough_to_recovery / 30.44).round(1) : nil

puts "📉 Max Drawdown: #{max_dd.round(2)}%"
$max_dd = max_dd.to_f

# ======================================================
# 📦 WHAT-IF: Recast trades with NEXT-DAY OPEN fills
# (keeps original results intact)
# ======================================================
begin
  puts "\n=== WHAT-IF: Next-Day Open Execution (no strategy refactor) ==="

  # Cache opens per symbol
  __opens_cache = {}

  def __load_opens_for_symbol(sym, cache, data_dir_fn: method(:data_csv_for))
    return cache[sym] if cache.key?(sym)
    path = data_dir_fn.call(sym)
    raise "Missing data for #{sym}" unless path && File.exist?(path)
    sep = detect_sep(path)
    rows = CSV.read(path, headers: true, col_sep: sep,
                    header_converters: ->(h){ h&.strip&.downcase&.gsub(/\s+/,'') },
                    converters: ->(f){ f&.strip })
    date_col = rows.headers.find { |h| h =~ /date|time/i }
    opens = rows['open'] ? rows['open'].map(&:to_f) : rows['close'].map(&:to_f)
    dates = rows[date_col].map { |d| (Date.parse(d) rescue nil) }
    # Build index: date -> open
    by_date = {}
    dates.each_with_index do |d, i|
      by_date[d] = opens[i] if d && opens[i]
    end
    # Also keep a sorted date array to jump to "next trading day"
    sorted = dates.compact.uniq.sort
    cache[sym] = { by_date: by_date, sorted: sorted }
  end

  def __next_session_open(sym, date_str, cache, data_dir_fn: method(:data_csv_for))
    d0 = Date.parse(date_str) rescue nil
    return nil unless d0
    data = __load_opens_for_symbol(sym, cache, data_dir_fn: data_dir_fn)
    sorted = data[:sorted]
    # find next trading day >= d0 + 1
    target = d0 + 1
    i = sorted.bsearch_index { |d| d >= target }
    return nil unless i
    d = sorted[i]
    px = data[:by_date][d]
    px ? { date: d, price: px } : nil
  end

  # 🔁 Replay all trades using next session's open for entry and exit
  recast = []
  skipped = 0

  all_trades.sort_by { |t| Date.parse(t[:entry_date]) rescue Date.new(1900,1,1) }.each do |t|
    sym = t[:symbol]
    en  = __next_session_open(sym, t[:entry_date], __opens_cache)
    ex  = __next_session_open(sym, t[:exit_date],  __opens_cache)
    if en && ex
      pct = ((ex[:price] - en[:price]) / en[:price] * 100.0).round(2)
      recast << {
        symbol: sym,
        entry_date: en[:date].to_s,
        exit_date:  ex[:date].to_s,
        entry: en[:price],
        exit:  ex[:price],
        pct_return: pct
      }
    else
      skipped += 1
    end
  end

  if recast.empty?
    puts "⚠️ Could not recast trades (missing next-session opens)."
  else
    # === Compute stats on recast ===
    overall_start = recast.first[:entry_date]
    overall_end   = recast.last[:exit_date]
    stats = compute_stats(recast, overall_start, overall_end)

    # MaxDD on equity curve
    eq = [1000.0]
    recast.sort_by { |t| t[:entry_date] }.each do |t|
      eq << eq[-1] * (1 + t[:pct_return].to_f / 100.0)
    end
    peak = eq.first
    maxdd = 0.0
    eq.each { |v| peak = [peak, v].max; dd = (peak - v) / peak * 100.0; maxdd = [maxdd, dd].max }

    # Files
    recast_trades_path = File.join(RESULTS_DIR, "whatif_nextopen_trades.csv")
    recast_yearly_path = File.join(RESULTS_DIR, "whatif_nextopen_yearly_breakdown.csv")

    # Save trades CSV
    CSV.open(recast_trades_path, "w") do |csv|
      csv << %w[symbol entry_date exit_date entry exit pct_return]
      recast.each { |t| csv << [t[:symbol], t[:entry_date], t[:exit_date], t[:entry], t[:exit], t[:pct_return]] }
    end

    # Build yearly (compounded) for recast
    cap = 1000.0
    yearly = {}
    recast.sort_by { |t| t[:entry_date] }.each do |t|
      y = t[:exit_date][0,4].to_i
      cap *= (1 + t[:pct_return].to_f / 100.0)
      yearly[y] ||= { start: (yearly[y-1] ? yearly[y-1][:end] : 1000.0), end: cap, trades: 0 }
      yearly[y][:end] = cap
      yearly[y][:trades] += 1
    end

    CSV.open(recast_yearly_path, "w") do |csv|
      csv << %w[year trades start_balance end_balance compounded_return]
      prev = 1000.0
      yearly.keys.sort.each do |y|
        eb = yearly[y][:end]
        cr = ((eb - prev) / prev * 100.0).round(2)
        csv << [y, yearly[y][:trades], prev.round(2), eb.round(2), cr]
        prev = eb
      end
    end
# === Yearly (Next-Open) adjusted for fees/slippage via knobs ===
adj_yearly_path = File.join(RESULTS_DIR, "whatif_nextopen_yearly_breakdown_adjusted.csv")
adj_equity = $start_equity
yearlyA         = {}

recast.sort_by { |t| Date.parse(t[:entry_date]) rescue Date.new(1900,1,1) }.each do |t|
  y = t[:exit_date][0,4].to_i
yearlyA[y] ||= { start: (yearlyA[y-1] ? yearlyA[y-1][:end] : $start_equity), end: nil, trades: 0 }

  gross_pct = t[:pct_return].to_f
  net_pct   = net_pct_after_costs(gross_pct, equity: adj_equity)

  adj_equity *= (1.0 + net_pct / 100.0)
  yearlyA[y][:end]    = adj_equity
  yearlyA[y][:trades] += 1
end

CSV.open(adj_yearly_path, "w") do |csv|
  csv << %w[year trades start_balance end_balance realistic_compounded_return]
    prev = $start_equity
  yearlyA.keys.sort.each do |y|
    eb = yearlyA[y][:end] || prev
    cr = ((eb - prev) / prev * 100.0).round(2)
    csv << [y, yearlyA[y][:trades], prev.round(2), eb.round(2), cr]
    prev = eb
  end
end

print_yearly_table(adj_yearly_path, title: "Yearly (Next-Open, Fees+Slippage)")

# --- Console summary (uses the global knobs) ---
trades_count = recast.size
total_fixed_fees_est = ($fee_fixed_usd.to_f * 2.0 * trades_count).round(2)
overall_start = recast.first[:entry_date]
overall_end   = recast.last[:exit_date]
adj_start = Date.parse(overall_start) rescue Date.parse(recast.first[:entry_date])
adj_end   = Date.parse(overall_end)   rescue Date.parse(recast.last[:exit_date])
adj_years = [(adj_end - adj_start).to_f / 365.0, 0.01].max
realistic_equity = adj_equity.to_f
realistic_cagr   = ((realistic_equity / $start_equity) ** (1.0 / adj_years) - 1.0) * 100.0

puts "-------------------------------------------------------------"
puts "💸 Adjusted for fees & slippage (Next-Open using knobs):"
puts "   Trades: #{trades_count}"
puts "   Fixed fee per side: $#{$fee_fixed_usd} | Percent fee (round-trip): #{$fee_rate_bps} bps | Slippage (round-trip): #{$slip_bps} bps"
puts "   Fixed-fee estimate (rough): $#{format('%.2f', total_fixed_fees_est)}"
puts "   → Realistic CAGR ≈ #{format('%.2f', realistic_cagr)}%"
puts "   → Realistic Final Equity ≈ $#{format('%.0f', realistic_equity)}"
puts "-------------------------------------------------------------"

# === Print to CMD ===
baseline_yearly   = File.join(RESULTS_DIR, "hybrid_v3_yearly_breakdown.csv")
nextopen_yearly   = File.join(RESULTS_DIR, "whatif_nextopen_yearly_breakdown.csv")

print_yearly_table(nextopen_yearly, title: "Yearly (Next-Open)")
compare_yearly(current_csv: baseline_yearly, nextopen_csv: nextopen_yearly)

    # === Print compact comparison ===
    orig_cagr   = ($real_cagr.to_f rescue 0.0)
    orig_pf     = ($profit_factor.to_f rescue 0.0)
    orig_maxdd  = ($max_dd.to_f rescue 0.0)
    delta_cagr  = (stats[:cagr].to_f - orig_cagr).round(2)
    delta_pf    = (stats[:pf].to_f   - orig_pf).round(2)
    delta_maxdd = (maxdd.to_f        - orig_maxdd).round(2)

    puts "-------------------------------------------------------------"
    puts "Next-Open (What-If) vs Current"
    puts "Trades:    #{recast.size}  (skipped #{skipped})"
    puts "CAGR:      #{stats[:cagr].round(2)}%   (Δ #{delta_cagr >= 0 ? '+' : ''}#{delta_cagr} pp)"
    puts "PF:        #{stats[:pf].round(2)}      (Δ #{delta_pf >= 0 ? '+' : ''}#{delta_pf})"
    puts "MaxDD:     #{maxdd.round(2)}%         (Δ #{delta_maxdd >= 0 ? '+' : ''}#{delta_maxdd} pp)"
    puts "Files:"
    puts "  • Trades (next-open): #{recast_trades_path}"
    puts "  • Yearly (next-open): #{recast_yearly_path}"
    puts "-------------------------------------------------------------"
  end
rescue => e
  warn "[WHATIF_NEXTOPEN_ERR] #{e.class}: #{e.message}"
end
# ======================================================

puts "   Peak:   #{peak_date}  (equity $#{equity_curve[peak_idx_at_dd].round(2)})"
puts "   Trough: #{trough_date}  (equity $#{equity_curve[trough_idx].round(2)})"
puts "   Days peak→trough: #{days_peak_to_trough}"

pf_for_grade = (profit_factor == "∞" ? 9_999 : profit_factor.to_f)
label, icon = grade_label(
  pf: pf_for_grade,
  win: win_rate,
  cagr: real_cagr,
  maxdd: max_dd,
  trades: total
)

puts "⭐ Rank: #{icon} #{label}  " \
     "(N=#{total}, PF=#{profit_factor}, Win=#{format('%.2f', win_rate)}%, " \
     "CAGR=#{format('%.2f', real_cagr)}%, MaxDD=#{format('%.2f', max_dd)}%)"

if recovery_date
  puts "📈 Recovery: #{recovery_date} (+#{days_trough_to_recovery} days / ~#{months_trough_to_recover} months)"
else
gap = ((equity_curve[-1] - equity_curve[peak_idx_at_dd]) / equity_curve[peak_idx_at_dd] * 100.0).round(2)
  puts "📈 Recovery: Not yet fully recovered (currently #{gap}%)"
end

# === Ulcer Index & Calmar Ratio ===
peak = equity_curve.first
drawdowns = []
equity_curve.each do |value|
  peak = [peak, value].max
  dd = (peak - value) / peak * 100.0
  drawdowns << dd
end
ulcer_index = Math.sqrt(drawdowns.map { |d| d**2 }.sum / drawdowns.size.to_f).round(2)

if all_trades.any?
  overall_start = all_trades.first[:entry_date]
  overall_end   = all_trades.last[:exit_date]
  overall_stats = compute_stats(all_trades, overall_start, overall_end)
  calmar_ratio  = max_dd.zero? ? 0 : (overall_stats[:cagr] / max_dd).round(2)
  overall_start = all_trades.first[:entry_date]
  overall_end   = all_trades.last[:exit_date]
  years_span    = ((Date.parse(overall_end) - Date.parse(overall_start)) / 365.0).round(2)  # ← ADD

else
  calmar_ratio = 0
end

puts "Ulcer Index: #{ulcer_index}"
puts "Calmar Ratio: #{calmar_ratio}"

# === Benchmark Comparison Summary ===
puts "\n📊 Performance Comparison (CAGR %)"
puts "-------------------------------------------------------------"
puts "Nasdaq-100 (QQQ)".ljust(28)      + "≈ 13%"
puts "S&P 500".ljust(28)               + "≈ 10%"
puts "Berkshire Hathaway".ljust(28)    + "≈ 20%"
puts "Avg Hedge Fund".ljust(28)        + "≈ 8–12%"
puts "Renaissance (Medallion)".ljust(28)+ "≈ 39% (net)"
puts "-------------------------------------------------------------"

# Save to CSV (optional)
CSV.open(File.join(RESULTS_DIR, "drawdown_report.csv"), "w") do |csv|
  csv << %w[metric value]
  csv << ["peak_date", peak_date]
  csv << ["trough_date", trough_date]
  csv << ["recovery_date", recovery_date]
  csv << ["max_drawdown_pct", max_dd.round(2)]
  csv << ["days_peak_to_trough", days_peak_to_trough]
  csv << ["days_trough_to_recovery", days_trough_to_recovery]
end

# === Save Summary Report (per symbol + total) ===
summary_path = File.join(RESULTS_DIR, "hybrid_v3_summary.csv")
FileUtils.mkdir_p(File.dirname(summary_path)) rescue nil

CSV.open(summary_path, "w") do |csv|  csv << %w[symbol trades win_rate pf cagr avg_return median_return best_year worst_year volatility sharpe sortino max_drawdown ulcer_index calmar_ratio]

  # ---- Per-symbol stats from the actual trades we executed above ----
  grouped = all_trades.group_by { |t| t[:symbol] }

  grouped.keys.sort.each do |sym|
    trades = grouped[sym]
    next if trades.nil? || trades.empty?

    # compute base stats
    start_date = [trades.map { |t| t[:entry_date] }, trades.map { |t| t[:exit_date] }].flatten.min
    end_date   = [trades.map { |t| t[:entry_date] }, trades.map { |t| t[:exit_date] }].flatten.max
    stats = compute_stats(trades, start_date, end_date)

    # equity curve
    equity_curve = [1000.0]
    trades.sort_by { |t| t[:entry_date] }.each do |t|
      equity_curve << equity_curve[-1] * (1 + t[:pct_return].to_f / 100.0)
    end

    # yearly returns (compounded per symbol)
    yearly = {}
    capital = 1000.0
    trades.sort_by { |t| t[:entry_date] }.each do |t|
      y = t[:exit_date][0,4].to_i
      capital *= (1 + t[:pct_return].to_f / 100.0)
      yearly[y] = capital
    end

    returns = []
    prev_balance = 1000.0
    yearly.keys.sort.each do |y|
      end_balance = yearly[y]
      returns << ((end_balance - prev_balance) / prev_balance * 100.0)
      prev_balance = end_balance
    end

    avg_return    = returns.empty? ? 0 : (returns.sum / returns.size).round(2)
    median_return = returns.empty? ? 0 : returns.sort[returns.size / 2].round(2)
    best_year     = returns.empty? ? 0 : returns.max.round(2)
    worst_year    = returns.empty? ? 0 : returns.min.round(2)

    mean = returns.empty? ? 0 : returns.sum / returns.size.to_f
    variance = returns.empty? ? 0 : returns.map { |r| (r - mean) ** 2 }.sum / returns.size.to_f
    volatility = Math.sqrt(variance).round(2)
    sharpe = volatility.zero? ? 0 : (avg_return / volatility).round(2)

    downside_returns = returns.select { |r| r < 0 }
    sortino = if downside_returns.any?
      dd_var = downside_returns.map { |r| r**2 }.sum / downside_returns.size.to_f
      (avg_return / Math.sqrt(dd_var)).round(2)
    else
      0
    end

    peak, max_dd, dd_list = equity_curve.first, 0.0, []
    equity_curve.each do |val|
      peak = [peak, val].max
      dd = (peak - val) / peak * 100.0
      max_dd = [max_dd, dd].max
      dd_list << dd
    end
    ulcer_index = dd_list.empty? ? 0 : Math.sqrt(dd_list.map { |d| d**2 }.sum / dd_list.size).round(2)
    calmar = max_dd.zero? ? 0 : (stats[:cagr] / max_dd).round(2)

    csv << [
      sym, stats[:trades], stats[:win_rate].round(2), stats[:pf].round(2), stats[:cagr].round(2),
      avg_return, median_return, best_year, worst_year, volatility, sharpe, sortino,
      max_dd.round(2), ulcer_index, calmar
    ]
  end

  # ---- Combined TOTAL stats ----
  if all_trades.any?
    equity_curve = [1000.0]
    all_trades.sort_by { |t| t[:entry_date] }.each do |t|
      equity_curve << equity_curve[-1] * (1 + t[:pct_return].to_f / 100.0)
    end

    peak, max_dd, dd_list = equity_curve.first, 0.0, []
    equity_curve.each do |val|
      peak = [peak, val].max
      dd = (peak - val) / peak * 100.0
      max_dd = [max_dd, dd].max
      dd_list << dd
    end
    ulcer_index = dd_list.empty? ? 0 : Math.sqrt(dd_list.map { |d| d**2 }.sum / dd_list.size).round(2)

    overall_start = all_trades.first[:entry_date]
    overall_end   = all_trades.last[:exit_date]
    overall_stats = compute_stats(all_trades, overall_start, overall_end)
    calmar_ratio  = max_dd.zero? ? 0 : (overall_stats[:cagr] / max_dd).round(2)

    # reuse the earlier yearly returns to compute avg/median/best/worst/vol/sharpe/sortino quickly
    # build per-year balances for TOTAL
    yearly_total = {}
    cap = 1000.0
    all_trades.sort_by { |t| t[:entry_date] }.each do |t|
      y = t[:exit_date][0,4].to_i
      cap *= (1 + t[:pct_return].to_f / 100.0)
      yearly_total[y] = cap
    end
    total_returns = []
    pb = 1000.0
    yearly_total.keys.sort.each do |y|
      eb = yearly_total[y]
      total_returns << ((eb - pb) / pb * 100.0)
      pb = eb
    end
    t_avg = total_returns.empty? ? 0 : (total_returns.sum / total_returns.size).round(2)
    t_mdn = total_returns.empty? ? 0 : total_returns.sort[total_returns.size / 2].round(2)
    t_best = total_returns.empty? ? 0 : total_returns.max.round(2)
    t_worst = total_returns.empty? ? 0 : total_returns.min.round(2)
    t_mean = total_returns.empty? ? 0 : total_returns.sum / total_returns.size.to_f
    t_var = total_returns.empty? ? 0 : total_returns.map { |r| (r - t_mean) ** 2 }.sum / total_returns.size.to_f
    t_vol = Math.sqrt(t_var).round(2)
    t_sharpe = t_vol.zero? ? 0 : (t_avg / t_vol).round(2)
    t_down = total_returns.select { |r| r < 0 }
    t_sortino = if t_down.any?
      ddv = t_down.map { |r| r**2 }.sum / t_down.size.to_f
      (t_avg / Math.sqrt(ddv)).round(2)
    else
      0
    end

    csv << [
      "TOTAL", overall_stats[:trades], overall_stats[:win_rate].round(2), overall_stats[:pf].round(2), overall_stats[:cagr].round(2),
      t_avg, t_mdn, t_best, t_worst, t_vol, t_sharpe, t_sortino,
      max_dd.round(2), ulcer_index, calmar_ratio
    ]
  end
end

# --- copy one row into METRICS_CSV right away (normal run) ---
if ENV["METRICS_CSV"].to_s != ""
  if export_metrics_if_possible(ENV["METRICS_CSV"], summary_path)
    ENV["METRICS_CSV_ALREADY_WRITTEN"] = "1"  # optional; your finalizer now ignores it, but harmless
  else
    puts "[BOT_METRICS] ⚠️ no valid row in #{summary_path}; finalizer will handle."
  end
end

puts "[DONE] Summary stats saved to #{RESULTS_DIR}/hybrid_v3_summary.csv"

# === Overlap Check (safety) ===
overlaps = []
all_trades.each_with_index do |t, i|
  all_trades[(i+1)..-1].each do |u|
    if Date.parse(t[:entry_date]) < Date.parse(u[:exit_date]) &&
       Date.parse(u[:entry_date]) < Date.parse(t[:exit_date])
      overlaps << [t, u]
    end
  end
end

puts "Overlap check: #{overlaps.empty? ? ' None found' : '⚠️ Overlaps detected!'}"

# ===============================
# BUILD MANUAL TRADES FILE (from executed signals)
# ===============================
manual_trades_path = File.join(RESULTS_DIR, "manual_trades.csv")

if File.exist?(File.join(RESULTS_DIR, "hybrid_v3_all_signals.csv"))
  signals = CSV.read(File.join(RESULTS_DIR, "hybrid_v3_all_signals.csv"), headers: true)
                .map { |r| r.to_h.transform_keys(&:strip) }

  manual_trades = []
  open_positions = {}

  signals.each do |s|
    next unless s["executed"]&.strip&.downcase == "done"

    symbol = s["symbol"]
    signal = s["signal"].upcase
    date   = s["date"]
    price  = s["close"].to_f

    if signal == "BUY"
      open_positions[symbol] = { entry_date: date, entry: price }
    elsif signal == "SELL" && open_positions[symbol]
      entry = open_positions[symbol]
      pct_return = ((price - entry[:entry]) / entry[:entry] * 100).round(2)
      manual_trades << {
        symbol: symbol,
        entry_date: entry[:entry_date],
        exit_date: date,
        entry: entry[:entry],
        exit: price,
        pct_return: pct_return
      }
      open_positions.delete(symbol)
    end
  end

  if manual_trades.any?
    CSV.open(manual_trades_path, "w") do |csv|
      csv << %w[symbol entry_date exit_date entry exit pct_return]
      manual_trades.each { |t| csv << [t[:symbol], t[:entry_date], t[:exit_date], t[:entry], t[:exit], t[:pct_return]] }
    end
    puts "[SAVED]  Manual trades saved to #{manual_trades_path} (#{manual_trades.size} completed trades)"
  else
    puts "[INFO] No completed manual trades found yet."
  end
else
  puts "[WARN] hybrid_v3_all_signals.csv not found — skipping manual trades export."
end

# =====================================================
# Ensure metrics CSV always has real result (not just BOOT)
# =====================================================
begin
  metrics_path = ENV["METRICS_CSV"]
  if metrics_path && File.exist?(metrics_path) && ENV["METRICS_CSV_ALREADY_WRITTEN"] != "1"
    lines = File.readlines(metrics_path)
    if lines.size <= 2
      CSV.open(metrics_path, "w") do |csv|
        csv << %w[symbol trades win_rate pf cagr max_drawdown]
        csv << ["DONE", 0, 0, 0, 0, 0]
      end
      puts "[SAFE_FIX] metrics CSV had only BOOT row → replaced with DONE placeholder"
    end
  end
rescue => e
  warn "[SAFE_FIX_ERR] #{e.class}: #{e.message}"
end

