#!/usr/bin/env ruby

$stdout.sync = true
$stderr.sync = true

puts "🔍 DEBUG BOOT CHECK: running from #{__FILE__}"
puts "🔍 Current working directory: #{Dir.pwd}"
puts "🔍 Ruby version: #{RUBY_VERSION}"
puts "🔍 Timestamp: #{Time.now.utc}"
sleep 1
$global_active_slots = 0
$active_tickers = []
# --- kill any leftover IO/preview monkey patches ---
begin
  $stdout = STDOUT
  $stderr = STDERR
  $stdout.sync = $stderr.sync = true

  if ::NilClass.method_defined?(:write)
     ::NilClass.send(:remove_method, :write) rescue nil
  end
  rescue => e
    warn "[IO_SHIM_NEUTER_FAIL] #{e.class}: #{e.message}"
  end

# Safe no-op writer for bad shims that call NilClass#write
begin
  unless ::NilClass.method_defined?(:write)
    ::NilClass.class_eval do
      def write(*)
        0
      end
    end
  end
rescue => e
  warn "[NIL_WRITE_PATCH_ERR] #{e.class}: #{e.message}"
end

require "csv"
require "fileutils"
require "optparse"
require "date"
require "set"
require "time"   # for iso8601

# --- HARDEN AGAINST BUGGY SHIMS ---
$stdout = STDOUT rescue $stdout
$stderr = STDERR rescue $stderr
$stdout.sync = $stderr.sync = true
# Some wrappers accidentally call `nil.join(...)`. Make it a no-op.
begin
  unless NilClass.method_defined?(:join)
    class NilClass
      def join(*); "" end
    end
  end
rescue => e
  warn "[NIL_JOIN_PATCH_ERR] #{e.class}: #{e.message}"
end

# FAST_TUNE EARLY METRICS STUB (must run before any require)
begin
  tuner_metrics = ENV["METRICS_CSV"].to_s
if !tuner_metrics.empty? && (!File.exist?(tuner_metrics) || File.size?(tuner_metrics).to_i < 20)
    FileUtils.mkdir_p(File.dirname(tuner_metrics)) rescue nil

    File.open(tuner_metrics, "w") do |io|
      io.puts "symbol,trades,win_rate,pf,cagr,max_drawdown"
      io.puts "BOOT,0,0,0,0,0"   #  placeholder row the finalizer is allowed to replace
    end

    ENV["METRICS_BOOT_PATH"] = tuner_metrics
    puts "[SYNC-EARLY] Boot metrics row written at #{tuner_metrics}"
  end
rescue => e
  warn "[SAFE_CSV_EARLY_ERR_FINAL] #{e.class}: #{e.message}"
end

# =====================================================
# Safe metrics writer for tuner (prevents Hash→Integer crash)
# =====================================================
def safe_write_metrics(path, data)
  begin
    FileUtils.mkdir_p(File.dirname(path)) rescue nil

    #  Flatten once immediately
    data = case data
           when Hash
             data.transform_values { |v| v.is_a?(Hash) ? v.values.first.to_s : v.to_s }
           when Array
             data.map(&:to_s)
           else
             [data.to_s]
           end

    CSV.open(path, "w") do |csv|
      if data.is_a?(Hash)
        csv << data.keys
        csv << data.values
      else
        csv << Array(data)
      end
    end
  rescue => e
    warn "[SAFE_WRITE_METRICS_ERR] #{e.class}: #{e.message}"
  end
end

$LOAD_PATH.unshift(File.join(BOT_ROOT, "lib"))

require File.join(BOT_ROOT, "lib", "symbol_policies", "fcx_volatility_policy")


BASE_DIR = BOT_ROOT

fcx_blocks = 0

puts "[BOOT] FCXVolPolicy loaded? #{defined?(SymbolPolicies::FCXVolatilityPolicy) ? 'YES' : 'NO'}"

if ENV["FCX_VOL_LOG"] == "1"
  puts "[FCX_VOL_POLICY] " \
       "SOFT=#{ENV.fetch('FCX_SOFT','0.070')} " \
       "HARD=#{ENV.fetch('FCX_HARD','0.110')} " \
       "GAPDN=#{ENV.fetch('FCX_GAPDN','0.030')} " \
       "GAPUP_SKIP=#{ENV.fetch('FCX_GAPUP_SKIP','0.040')} " \
       "KILL_GAPDN=#{ENV.fetch('FCX_KILL_GAPDN','0.040')} " \
       "SURGE=#{ENV.fetch('FCX_SURGE','0.20')}"
end

puts "[FCX_VOL] loaded=#{defined?(SymbolPolicies::FCXVolatilityPolicy) ? 'yes' : 'no'}"

def export_metrics_if_possible(metrics_path, summary_path)
  return false unless metrics_path && !metrics_path.empty? && File.exist?(summary_path)

  rows = CSV.read(summary_path, headers: true)
  # Prefer a real symbol row with trades; else TOTAL as a fallback
  row  = rows.find { |r| (r["symbol"] || "").upcase != "TOTAL" && r["trades"].to_i > 0 } ||
         rows.find { |r| (r["symbol"] || "").upcase == "TOTAL" }

  return false unless row

  CSV.open(metrics_path, "w") do |csv|
    csv << %w[symbol trades win_rate pf cagr max_drawdown]
    csv << [row["symbol"], row["trades"], row["win_rate"], row["pf"], row["cagr"], row["max_drawdown"]]
  end

  puts "[BOT_METRICS]  metrics copied → #{metrics_path}"
  true
end

$profit_factor ||= 0.0   # default to 0.0 to avoid nil errors before calculation
$win_rate      ||= 0.0   # initialized to 0.0 (will be updated after trades)
$real_cagr     ||= 0.0   # avoids nil when printing stats early
$max_dd        ||= 0.0   # default value before drawdown is computed
$all_trades    ||= []    # initialize storage for trades

# Force tuner flag if a metrics file is present (Windows fix)
ENV["FAST_TUNE"] ||= "1" if ENV["METRICS_CSV"]
ENV["FAST_TUNE"] ||= "0"

# no-op writer while sweeping
def write_csv_unless_fast(path, header_or_row, mode: "a")
  return if $FAST_SWEEP
  CSV.open(path, mode) { |csv| csv << header_or_row }
end

# set by fast_sweep.rb when it requires this file
$FAST_SWEEP ||= false
$FAST_SWEEP = %w[1 true yes].include?(ENV["FAST_SWEEP"].to_s.downcase)

$vol_cfg ||= {}

class String
  def red;    "\e[31m#{self}\e[0m" end
  def green;  "\e[32m#{self}\e[0m" end
  def yellow; "\e[33m#{self}\e[0m" end
end

# ===============================
# DEBUG LOGGING SYSTEM
# ===============================

DEBUG_LOG = File.join(BASE_DIR, "storage", "debug", "hybrid_v3_log.txt")
FileUtils.mkdir_p(File.dirname(DEBUG_LOG))
File.write(DEBUG_LOG, "")   # clear file each run

def log_line(str)
  File.open(DEBUG_LOG, "a") { |f| f.puts(str) }
end

# ===============================
# CONFIGURATION
# ===============================

puts "[EARLY ENV] SMA=#{$sma_filter}, OS=#{$oversold}, OB=#{$overbought}, STOP=#{$atr_stop}, PROF=#{$atr_profit}, BE=#{$breakout_entry}, BX=#{$breakout_exit}"
puts "[DEBUG PARAMS] SMA=#{$sma_filter}, OS=#{$oversold}, OB=#{$overbought}, STOP=#{$atr_stop}, PROF=#{$atr_profit}, BE=#{$breakout_entry}, BX=#{$breakout_exit}"

BASE_DIR    = BOT_ROOT
DATA_DIR    = File.join(BASE_DIR, "data/clean")
HARD_STOP_PCT = 12.0  
$start_equity ||= (ENV["START_EQUITY"] || "1000").to_f


TAKE_PROFIT_MAP = {
  "NVDA" => 5.0,
  "MOD"  => 4.0,
  "LRCX" => 6.0,
  "VRT"  => 5.5,
  "VST"  => 4.5,
  "AMD"  => 5.0,
  "DELL" => 6.0,
  "TSM"  => 5.0,
  "GS"   => 4.0,
  "TSLA" => 8.0
}


# === COST MODEL (set to 0 for research; set real values for go-live)
$fee_fixed_usd = (ENV["FEE_FIXED_USD"] || "0").to_f   # per SIDE (e.g., 6.95)
$fee_rate_bps  = (ENV["FEE_RATE_BPS"]  || "0").to_f   # round-trip in bps (e.g., 6 = 0.06%)
$slip_bps      = (ENV["SLIPPAGE_BPS"]  || "10").to_f  # round-trip in bps; 10 = 0.10%

def net_pct_after_costs(gross_pct, equity:)
  # fixed $ fees per *side* → round-trip = 2 * fee
  fixed_fee_pct = $fee_fixed_usd > 0 ? ((2.0 * $fee_fixed_usd) / equity) * 100.0 : 0.0
  # bps are “hundredths of a percent”; fee_rate_bps is **round-trip**
  percent_fee_pct = ($fee_rate_bps / 100.0)
  slip_pct = ($slip_bps / 100.0)
  gross_pct - fixed_fee_pct - percent_fee_pct - slip_pct
end

early_profile = ENV["BOT_PROFILE"] || ENV["BOT_NAMESPACE"] || "default"
early_bot     = ENV["BOT_NAME"]    || "vanilla"

RESULTS_DIR = File.join(BASE_DIR, "storage", early_profile, early_bot)
FileUtils.mkdir_p(RESULTS_DIR) rescue nil

ENV["METRICS_CSV"] ||= File.join(RESULTS_DIR, "metrics", "latest.csv")
FileUtils.mkdir_p(File.dirname(ENV["METRICS_CSV"])) rescue nil

SWEEP_LIVE = File.join(RESULTS_DIR, "sweep_live.csv")
SWEEP_BEST = File.join(RESULTS_DIR, "sweep_best_so_far.csv")

# --- Symbol/file helpers (handles *_GoogleFinance_AutoUpToDate) ---
def strip_suffix(sym)
  sym.to_s.sub(/_GoogleFinance_AutoUpToDate\z/i, "")
end

def data_csv_for(symbol)
  sym  = symbol.to_s
  base = strip_suffix(sym)

  candidates = [
    File.join(DATA_DIR, "#{sym}.csv"),
    File.join(DATA_DIR, "#{base}_GoogleFinance_AutoUpToDate.csv"),
    File.join(DATA_DIR, "#{base}.csv")
  ]

  hit = candidates.find { |p| File.exist?(p) }
  return hit if hit

  # last-chance: case-insensitive scan
  Dir.glob(File.join(DATA_DIR, "*.csv")).find do |p|
    b = File.basename(p).downcase
b == "#{base.downcase}_googlefinance_autouptodate.csv" || b.start_with?(base.downcase)
  end
end

# --- Load a benchmark (e.g., QQQ) close series and SMA(200) + slope ---
$benchmark_cache ||= {}

def load_benchmark(series_name = "QQQ_GoogleFinance_AutoUpToDate")
  return $benchmark_cache[series_name] if $benchmark_cache.key?(series_name)

  path = data_csv_for(series_name)
  unless path && File.exist?(path)
    warn "[REGIME] Benchmark #{series_name} missing; regime filter will be OFF"
    return $benchmark_cache[series_name] = nil
  end

  sep   = detect_sep(path)
  rows  = CSV.read(path, headers: true, col_sep: sep,
                   header_converters: ->(h){ h&.strip&.downcase&.gsub(/\s+/,'') },
                   converters: ->(f){ f&.strip })

  raw_dates = rows[rows.headers.find { |h| h =~ /date|time/i }]
  dates     = raw_dates.map { |d| Date.parse(d) rescue nil }  

  close = rows['close'].map(&:to_f)

  sma200 = []
  close.each_with_index do |_, i|
    sma200 << (i >= 199 ? close[(i-199)..i].sum / 200.0 : nil)
  end

  slope = []
  sma200.each_with_index do |v, i|
    slope << (i >= 5 && v && sma200[i-5] ? v - sma200[i-5] : nil)
  end

  $benchmark_cache[series_name] = {
    dates: dates,   # now Date objects, not strings
    close: close,
    sma200: sma200,
    slope: slope
  }
end

def regime_ok_fast(bi, bench = nil)
  return true unless bench
  return true unless bi && bi >= 0

  sma = bench[:sma200][bi]
  slp = bench[:slope][bi]
  cls = bench[:close][bi]

  return true unless sma && slp

  above = cls > sma
  slope_up = slp > 0

  above && slope_up
end

# --- Stable metrics path + log it once ---
ENV["METRICS_CSV"] = File.expand_path(
  ENV["METRICS_CSV"].to_s.empty? ?
    File.join(RESULTS_DIR, "metrics", "latest.csv") :
    ENV["METRICS_CSV"]
)

begin
  FileUtils.mkdir_p(File.dirname(ENV["METRICS_CSV"]))
rescue => e
  warn "[METRICS_DIR_ERR] #{e.class}: #{e.message}"
end

